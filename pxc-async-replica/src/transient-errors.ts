import { log, sleep } from "./log";

function errorChain(err: unknown): unknown[] {
  const out: unknown[] = [];
  let cur: unknown = err;
  let depth = 0;
  while (cur !== undefined && cur !== null && depth < 8) {
    out.push(cur);
    cur = (cur as { cause?: unknown }).cause;
    depth += 1;
  }
  return out;
}

function httpStatusFromItem(item: unknown): number | undefined {
  if (item === null || item === undefined) return undefined;
  const i = item as Record<string, unknown>;
  if (typeof i.statusCode === "number") return i.statusCode;
  const resp = i.response as Record<string, unknown> | undefined;
  if (resp && typeof resp.statusCode === "number") return resp.statusCode as number;
  if (typeof i.code === "number" && i.code >= 400 && i.code < 600) return i.code;
  const body = i.body as Record<string, unknown> | undefined;
  const st = body?.status as Record<string, unknown> | undefined;
  if (typeof st?.code === "number") return st.code as number;
  const md = i.$metadata as { httpStatusCode?: number } | undefined;
  if (typeof md?.httpStatusCode === "number") return md.httpStatusCode;
  return undefined;
}

/**
 * Errors that will not be fixed by time/backoff alone (bad env, RBAC, wrong Secret shape).
 * The process exits so the operator notices misconfiguration.
 */
export function isDefinitelyFatalError(err: unknown): boolean {
  if (!err) return false;
  const fullMsg = errorChain(err)
    .map((item) => String((item as Error)?.message ?? item))
    .join(" | ");

  if (/Missing required env var:/.test(fullMsg)) return true;
  if (/DEST_NS\/PXC_NAMESPACE is not set/.test(fullMsg)) return true;
  if (/could not read pod namespace/.test(fullMsg)) return true;
  if (/SOURCE_HOSTS must contain at least one hostname/.test(fullMsg)) return true;
  if (/REPLICATION_CHANNEL_NAME must be non-empty/.test(fullMsg)) return true;
  if (/must be 1-64 characters \[A-Za-z0-9_\]/.test(fullMsg)) return true;
  if (/Secret missing data key:/.test(fullMsg)) return true;
  if (/Secret \S+ has no data/.test(fullMsg)) return true;
  if (/Invalid URL|is not a valid URL|reject non-mysql protocols/i.test(fullMsg)) return true;

  for (const item of errorChain(err)) {
    const st = httpStatusFromItem(item);
    if (st === 401 || st === 403) return true;
  }
  return false;
}

/** True for DNS blips, common TCP timeouts, and brief API / gateway overload (retry-safe). */
export function isTransientNetworkError(err: unknown): boolean {
  for (const item of errorChain(err)) {
    const code = (item as NodeJS.ErrnoException)?.code;
    if (
      code === "EAI_AGAIN" ||
      code === "ENOTFOUND" ||
      code === "ETIMEDOUT" ||
      code === "ECONNRESET" ||
      code === "ECONNREFUSED" ||
      code === "ENETUNREACH" ||
      code === "EPIPE"
    ) {
      return true;
    }
    const msg = String((item as Error)?.message ?? item);
    if (
      /getaddrinfo EAI_AGAIN|EAI_AGAIN|ENOTFOUND|ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENETUNREACH|socket hang up|TLS handshake timeout|fetch failed/i.test(
        msg
      )
    ) {
      return true;
    }
    const status =
      (item as { statusCode?: number })?.statusCode ??
      (item as { response?: { statusCode?: number } })?.response?.statusCode;
    if (status === 429 || status === 502 || status === 503 || status === 504) return true;

    const numCode = (item as { code?: number }).code;
    if (numCode === 429 || numCode === 502 || numCode === 503 || numCode === 504) return true;

    const retryable = (item as { $metadata?: { httpStatusCode?: number } })?.$metadata?.httpStatusCode;
    if (retryable === 429 || retryable === 502 || retryable === 503 || retryable === 504) return true;
  }
  return false;
}

/**
 * Broad “try again later” classification for Kubernetes calls, S3, MySQL pools, and similar.
 * Anything not {@link isDefinitelyFatalError} defaults to recoverable so the controller avoids crash loops.
 */
export function isRecoverableInfrastructureError(err: unknown): boolean {
  if (isDefinitelyFatalError(err)) return false;
  if (isTransientNetworkError(err)) return true;

  for (const item of errorChain(err)) {
    const st = httpStatusFromItem(item);
    if (st === 404 || st === 408 || st === 409 || st === 425 || st === 429) return true;
    if (st !== undefined && st >= 500 && st < 600) return true;

    const errno = (item as NodeJS.ErrnoException)?.code;
    if (errno === "EHOSTUNREACH" || errno === "EAI_NODATA") return true;

    const msg = String((item as Error)?.message ?? item);
    if (
      /PROTOCOL_CONNECTION_LOST|ECONNRESET|ETIMEDOUT|server has gone away|Gone away|Communications link failure|Connection lost|Connection refused|pool is closed|Too many connections|read ECONNRESET|write ECONNRESET|SSL connection error|Broken pipe|RequestTimeout|SlowDown|Throttling|ServiceUnavailable|InternalError|ECONNABORTED/i.test(
        msg
      )
    ) {
      return true;
    }

    const mysqlErrno = (item as { errno?: number }).errno;
    if (typeof mysqlErrno === "number") {
      if ([2002, 2003, 2006, 2013].includes(mysqlErrno)) return true;
    }
  }

  return true;
}

export async function retryWithBackoff<T>(options: {
  label: string;
  fn: () => Promise<T>;
  maxAttempts?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  isRetryable?: (err: unknown) => boolean;
  isShuttingDown?: () => boolean;
}): Promise<T> {
  const maxAttempts = options.maxAttempts ?? 30;
  const base = options.baseDelayMs ?? 1000;
  const maxDelay = options.maxDelayMs ?? 60_000;
  const isRetryable = options.isRetryable ?? isRecoverableInfrastructureError;
  let attempt = 0;
  let delay = base;
  while (true) {
    try {
      return await options.fn();
    } catch (e) {
      attempt += 1;
      if (options.isShuttingDown?.()) throw e;
      if (attempt >= maxAttempts || !isRetryable(e)) throw e;
      const msg = e instanceof Error ? e.message : String(e);
      log(`${options.label}: recoverable failure (${attempt}/${maxAttempts}): ${msg}; retrying in ${delay}ms`);
      await sleep(delay);
      delay = Math.min(maxDelay, Math.floor(delay * 1.5) + Math.floor(Math.random() * 500));
    }
  }
}

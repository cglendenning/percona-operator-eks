function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n)}…(truncated ${s.length - n} chars)` : s;
}

export function formatK8sError(err: unknown): string {
  const maybeApi = err as { code?: number; body?: unknown; message?: string; headers?: Record<string, string> };
  if (typeof maybeApi?.code === "number" && "body" in maybeApi) {
    const parts: string[] = [`Kubernetes API error code=${maybeApi.code}`];
    const body = maybeApi.body as Record<string, unknown> | undefined;
    const k8sMessage = body?.message ?? (body?.status as Record<string, unknown> | undefined)?.message;
    const reason = body?.reason ?? (body?.status as Record<string, unknown> | undefined)?.reason;
    if (reason) parts.push(`reason=${JSON.stringify(reason)}`);
    if (k8sMessage) parts.push(`k8sMessage=${JSON.stringify(k8sMessage)}`);
    if (body) {
      let bodyStr: string;
      try {
        bodyStr = typeof body === "string" ? body : JSON.stringify(body);
      } catch {
        bodyStr = String(body);
      }
      parts.push(`body=${JSON.stringify(truncate(bodyStr, 2000))}`);
    }
    if (maybeApi.message && maybeApi.message !== "HTTP request failed") {
      parts.push(`error=${JSON.stringify(maybeApi.message)}`);
    }
    if (maybeApi.code === 403) parts.push(`hint="RBAC Forbidden (check Role/Binding + ServiceAccount)"`);
    return parts.join(" ");
  }

  const e = err as {
    message?: string;
    statusCode?: number;
    response?: { statusCode?: number; body?: any; request?: { method?: string; url?: string } };
    body?: any;
  };

  const status = e?.statusCode ?? e?.response?.statusCode;
  const method = e?.response?.request?.method;
  const url = e?.response?.request?.url;

  const body = e?.body ?? e?.response?.body;
  const k8sMessage = body?.message ?? body?.status?.message;
  const reason = body?.reason ?? body?.status?.reason;
  const details = body?.details ?? body?.status?.details;

  const parts: string[] = [];
  parts.push("HTTP request failed");

  if (status) parts.push(`status=${status}`);
  if (method) parts.push(`method=${method}`);
  if (url) parts.push(`url=${url}`);

  if (reason) parts.push(`reason=${JSON.stringify(reason)}`);
  if (k8sMessage) parts.push(`k8sMessage=${JSON.stringify(k8sMessage)}`);
  if (details) parts.push(`details=${JSON.stringify(details)}`);

  if (body) {
    let bodyStr: string;
    try {
      bodyStr = typeof body === "string" ? body : JSON.stringify(body);
    } catch {
      bodyStr = String(body);
    }
    parts.push(`body=${JSON.stringify(truncate(bodyStr, 2000))}`);
  }

  const msg = String(e?.message ?? err);
  if (/ENOTFOUND|EAI_AGAIN/.test(msg)) parts.push(`hint="DNS resolution issue inside pod"`);
  if (/ETIMEDOUT|timed out|Timeout/i.test(msg)) parts.push(`hint="network timeout to apiserver"`);
  if (/certificate|x509|TLS/i.test(msg)) parts.push(`hint="TLS/cert issue to apiserver"`);
  if (status === 403 || /Forbidden/i.test(String(k8sMessage || msg))) {
    parts.push(`hint="RBAC Forbidden (check Role/Binding + ServiceAccount)"`);
  }

  if (msg && msg !== "HTTP request failed") parts.push(`error=${JSON.stringify(msg)}`);

  return parts.join(" ");
}

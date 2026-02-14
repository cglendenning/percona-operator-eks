// src/index.ts
import * as k8s from "@kubernetes/client-node";

type Obj = Record<string, any>;

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function isoNow(): string {
  return new Date().toISOString();
}

function log(msg: string): void {
  process.stdout.write(`[${isoNow()}] ${msg}\n`);
}

function asString(x: any): string {
  return typeof x === "string" ? x : "";
}

function matchesRunningState(state: string | undefined): boolean {
  return state === "Starting" || state === "Running";
}

function parseCompletedAsMillis(completed: string, creationTimestamp: string): number {
  const t = completed || creationTimestamp;
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? ms : 0;
}

function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n) + `…(truncated ${s.length - n} chars)` : s;
}

function parseS3Bucket(destination: string): string {
  // destination format: s3://bucket-name/path/to/backup
  const match = destination.match(/^s3:\/\/([^\/]+)/);
  if (!match) {
    throw new Error(`Cannot parse S3 bucket from destination: ${destination}`);
  }
  return match[1];
}

function formatK8sError(err: any): string {
  const status = err?.statusCode ?? err?.response?.statusCode;
  const method = err?.response?.request?.method ?? err?.response?.req?.method ?? err?.method;
  const url = err?.response?.request?.url ?? err?.response?.req?.url ?? err?.url;

  const body = err?.body ?? err?.response?.body ?? err?.response?.data;

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

  const msg = String(err?.message ?? err);
  if (/ENOTFOUND|EAI_AGAIN/.test(msg)) parts.push(`hint="DNS resolution issue inside pod"`);
  if (/ETIMEDOUT|timed out|Timeout/i.test(msg)) parts.push(`hint="network timeout to apiserver"`);
  if (/certificate|x509|TLS/i.test(msg)) parts.push(`hint="TLS/cert issue to apiserver"`);
  if (status === 403 || /Forbidden/i.test(String(k8sMessage || msg))) {
    parts.push(`hint="RBAC Forbidden (check ClusterRole/Binding + ServiceAccount)"`);
  }

  // Preserve original message too (often contains low-level socket info)
  if (msg && msg !== "HTTP request failed") parts.push(`error=${JSON.stringify(msg)}`);

  return parts.join(" ");
}

async function main() {
  const SOURCE_NS = env("SOURCE_NS");
  const DEST_NS = env("DEST_NS");
  const DEST_PXC_CLUSTER = env("DEST_PXC_CLUSTER");
  const DEST_STORAGE_NAME = env("DEST_STORAGE_NAME");
  const TRACKING_CM = env("TRACKING_CM");
  const SLEEP_SECONDS = Number(env("SLEEP_SECONDS"));
  const S3_CREDENTIALS_SECRET = env("S3_CREDENTIALS_SECRET");
  const S3_REGION = env("S3_REGION");
  const S3_ENDPOINT_URL = env("S3_ENDPOINT_URL");

  // If your CRD version differs, override with env var
  const PXC_API_VERSION = process.env.PXC_API_VERSION || "v1";

  const kc = new k8s.KubeConfig();
  kc.loadFromDefault();

  const core = kc.makeApiClient(k8s.CoreV1Api);
  const custom = kc.makeApiClient(k8s.CustomObjectsApi);

  let shuttingDown = false;
  const shutdown = () => {
    if (!shuttingDown) {
      shuttingDown = true;
      log("SIGTERM received, exiting controller");
    }
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  async function getLastRestoreRecord(): Promise<{ lastCompleted: string; lastDestination: string }> {
    try {
      log(`Reading tracking ConfigMap ${TRACKING_CM} in ns=${DEST_NS}`);
      const resp = await core.readNamespacedConfigMap(TRACKING_CM, DEST_NS);
      const data = resp.body.data || {};
      return {
        lastCompleted: asString(data["last_completed"]),
        lastDestination: asString(data["last_destination"]),
      };
    } catch (e: any) {
      if (e?.response?.statusCode === 404) {
        log(`Tracking ConfigMap ${TRACKING_CM} not found (first run); proceeding`);
        return { lastCompleted: "", lastDestination: "" };
      }
      throw e;
    }
  }

  async function setLastRestoreRecord(completed: string, destination: string): Promise<void> {
    const cm: k8s.V1ConfigMap = {
      apiVersion: "v1",
      kind: "ConfigMap",
      metadata: { name: TRACKING_CM, namespace: DEST_NS },
      data: {
        last_completed: completed,
        last_destination: destination,
      },
    };

    try {
      log(`Creating tracking ConfigMap ${TRACKING_CM} in ns=${DEST_NS}`);
      await core.createNamespacedConfigMap(DEST_NS, cm);
      return;
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) {
        // 409 = already exists
        throw e;
      }
    }

    log(`Patching tracking ConfigMap ${TRACKING_CM} in ns=${DEST_NS}`);
    const patchBody = {
      data: {
        last_completed: completed,
        last_destination: destination,
      },
    };

    // NOTE: Some @kubernetes/client-node versions include a 'force?: boolean' arg.
    // We pass an extra undefined so our options object lands in the correct slot.
    await core.patchNamespacedConfigMap(
      TRACKING_CM,
      DEST_NS,
      patchBody as any,
      undefined, // pretty
      undefined, // dryRun
      undefined, // fieldManager
      undefined, // fieldValidation
      undefined, // force (exists in some versions)
      { headers: { "Content-Type": "application/merge-patch+json" } }
    );
  }

  async function newestSucceededBackup(): Promise<{ completed: string; destination: string } | null> {
    log(`Listing backups in ns=${SOURCE_NS}`);
    const resp: any = await custom.listNamespacedCustomObject(
      "pxc.percona.com",
      PXC_API_VERSION,
      SOURCE_NS,
      "perconaxtradbclusterbackups"
    );

    const items: Obj[] = (resp.body?.items || []) as Obj[];
    const succeeded = items.filter((it) => asString(it?.status?.state) === "Succeeded");
    if (succeeded.length === 0) return null;

    succeeded.sort((a, b) => {
      const aMs = parseCompletedAsMillis(asString(a?.status?.completed), asString(a?.metadata?.creationTimestamp));
      const bMs = parseCompletedAsMillis(asString(b?.status?.completed), asString(b?.metadata?.creationTimestamp));
      return aMs - bMs;
    });

    const newest = succeeded[succeeded.length - 1];
    return {
      completed: asString(newest?.status?.completed),
      destination: asString(newest?.status?.destination),
    };
  }

  async function restoreInProgress(): Promise<boolean> {
    log(`Listing restores in ns=${DEST_NS} to check in-progress`);
    const resp: any = await custom.listNamespacedCustomObject(
      "pxc.percona.com",
      PXC_API_VERSION,
      DEST_NS,
      "perconaxtradbclusterrestores"
    );

    const items: Obj[] = (resp.body?.items || []) as Obj[];
    for (const it of items) {
      const state = asString(it?.status?.state);
      if (matchesRunningState(state)) return true;
    }
    return false;
  }

  async function createRestoreCR(restoreName: string, destination: string): Promise<void> {
    const bucket = parseS3Bucket(destination);
    
    const body: Obj = {
      apiVersion: "pxc.percona.com/v1",
      kind: "PerconaXtraDBClusterRestore",
      metadata: { name: restoreName, namespace: DEST_NS },
      spec: {
        pxcCluster: DEST_PXC_CLUSTER,
        backupSource: {
          destination,
          s3: {
            bucket,
            credentialsSecret: S3_CREDENTIALS_SECRET,
            region: S3_REGION,
            endpointUrl: S3_ENDPOINT_URL,
          },
        },
      },
    };

    log(`Creating restore CR ${restoreName} in ns=${DEST_NS}`);
    await custom.createNamespacedCustomObject(
      "pxc.percona.com",
      PXC_API_VERSION,
      DEST_NS,
      "perconaxtradbclusterrestores",
      body
    );
  }

  async function getRestoreState(restoreName: string): Promise<string> {
    try {
      const resp: any = await custom.getNamespacedCustomObject(
        "pxc.percona.com",
        PXC_API_VERSION,
        DEST_NS,
        "perconaxtradbclusterrestores",
        restoreName
      );
      return asString(resp.body?.status?.state);
    } catch {
      return "";
    }
  }

  async function getPXCClusterReady(): Promise<boolean> {
    try {
      const resp: any = await custom.getNamespacedCustomObject(
        "pxc.percona.com",
        PXC_API_VERSION,
        DEST_NS,
        "perconaxtradbclusters",
        DEST_PXC_CLUSTER
      );
      const status = asString(resp.body?.status?.status);
      return status === "ready";
    } catch {
      return false;
    }
  }

  async function waitRestoreSucceeded(
    restoreName: string,
    timeoutSeconds: number
  ): Promise<"succeeded" | "failed" | "timeout"> {
    log(`Waiting for restore ${restoreName} to reach Succeeded (timeout=${timeoutSeconds}s)`);
    const start = Date.now();
    const timeoutMs = timeoutSeconds * 1000;

    let restoreSucceeded = false;

    while (!shuttingDown) {
      const state = await getRestoreState(restoreName);

      if (state === "Failed" || state === "Error") return "failed";

      if (state === "Succeeded") {
        if (!restoreSucceeded) {
          log(`Restore ${restoreName} reports Succeeded; now waiting for PXC cluster ${DEST_PXC_CLUSTER} to be Ready`);
          restoreSucceeded = true;
        }

        // Restore CR shows succeeded, now check if PXC cluster is actually Ready
        if (await getPXCClusterReady()) {
          log(`PXC cluster ${DEST_PXC_CLUSTER} is Ready`);
          return "succeeded";
        }
      }

      if (Date.now() - start > timeoutMs) return "timeout";
      await sleep(10_000);
    }
    return "timeout";
  }

  log(`pxc-auto-restore controller starting. source=${SOURCE_NS} dest=${DEST_NS} destCluster=${DEST_PXC_CLUSTER}`);

  while (!shuttingDown) {
    try {
      if (await restoreInProgress()) {
        log(`Restore already in progress in ${DEST_NS}; sleeping ${SLEEP_SECONDS}s`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const newest = await newestSucceededBackup();
      if (!newest) {
        log(`No Succeeded backup found in ${SOURCE_NS}; sleeping ${SLEEP_SECONDS}s`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const newestCompleted = newest.completed;
      const newestDestination = newest.destination;

      if (!newestDestination) {
        log(`Newest backup has empty .status.destination; cannot restore-to-new-cluster; sleeping ${SLEEP_SECONDS}s`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const { lastCompleted, lastDestination } = await getLastRestoreRecord();

      const alreadyRestored =
        !!lastCompleted &&
        lastCompleted === newestCompleted &&
        lastDestination === newestDestination;

      if (alreadyRestored) {
        log(`Already restored latest backup (completed=${newestCompleted}); sleeping ${SLEEP_SECONDS}s`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const restoreName = `auto-restore-${new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}`;
      log(`Triggering restore ${restoreName} from destination=${newestDestination} (completed=${newestCompleted})`);

      // Double-check no restore is in progress before creating (safety against race conditions)
      if (await restoreInProgress()) {
        log(`Restore started by another process; skipping creation`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      await createRestoreCR(restoreName, newestDestination);

      const result = await waitRestoreSucceeded(restoreName, 7200);
      if (result === "succeeded") {
        log(`Restore succeeded: ${restoreName}; recording completed=${newestCompleted} destination=${newestDestination}`);
        await setLastRestoreRecord(newestCompleted, newestDestination);
      } else {
        log(`Restore did not succeed (name=${restoreName}, result=${result}). Will retry on next loop.`);
      }
    } catch (e: any) {
      log(`ERROR: ${formatK8sError(e)}`);
    }

    await sleep(SLEEP_SECONDS * 1000);
  }

  process.exit(0);
}

main().catch((e) => {
  log(`FATAL: ${formatK8sError(e)}`);
  process.exit(1);
});


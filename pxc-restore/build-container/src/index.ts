import * as k8s from "@kubernetes/client-node";

type Obj = Record<string, any>;

function env(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return v;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function isoNow(): string {
  return new Date().toISOString();
}

function log(msg: string): void {
  // Match your prior log format closely
  process.stdout.write(`[${isoNow()}] ${msg}\n`);
}

function matchesRunningState(state: string | undefined): boolean {
  return state === "Starting" || state === "Running";
}

function asString(x: any): string {
  return typeof x === "string" ? x : "";
}

function parseCompletedAsMillis(completed: string, creationTimestamp: string): number {
  // Use completed when available; fall back to creationTimestamp
  const t = completed || creationTimestamp;
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? ms : 0;
}

async function main() {
  const SOURCE_NS = env("SOURCE_NS");
  const DEST_NS = env("DEST_NS");
  const DEST_PXC_CLUSTER = env("DEST_PXC_CLUSTER");
  const DEST_STORAGE_NAME = env("DEST_STORAGE_NAME");
  const TRACKING_CM = env("TRACKING_CM");
  const SLEEP_SECONDS = Number(env("SLEEP_SECONDS"));

  // Optional override if your CRD version differs
  const PXC_API_VERSION = process.env.PXC_API_VERSION || "v1";

  const kc = new k8s.KubeConfig();
  kc.loadFromDefault(); // In-cluster: reads serviceaccount token; local: uses kubeconfig

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
      const resp = await core.readNamespacedConfigMap(TRACKING_CM, DEST_NS);
      const data = resp.body.data || {};
      return {
        lastCompleted: asString(data["last_completed"]),
        lastDestination: asString(data["last_destination"]),
      };
    } catch (e: any) {
      // Not found is fine
      if (e?.response?.statusCode === 404) {
        return { lastCompleted: "", lastDestination: "" };
      }
      throw e;
    }
  }

  async function setLastRestoreRecord(completed: string, destination: string): Promise<void> {
    const body: k8s.V1ConfigMap = {
      apiVersion: "v1",
      kind: "ConfigMap",
      metadata: { name: TRACKING_CM, namespace: DEST_NS },
      data: {
        last_completed: completed,
        last_destination: destination,
      },
    };

    try {
      // Try replace if exists
      await core.replaceNamespacedConfigMap(TRACKING_CM, DEST_NS, body);
    } catch (e: any) {
      if (e?.response?.statusCode === 404) {
        await core.createNamespacedConfigMap(DEST_NS, body);
        return;
      }
      // If replace fails due to conflict, retry with patch
      const patch = [
        { op: "add", path: "/data", value: body.data },
      ];
      await core.patchNamespacedConfigMap(
        TRACKING_CM,
        DEST_NS,
        patch as any,
        undefined,
        undefined,
        undefined,
        undefined,
        { headers: { "Content-Type": "application/json-patch+json" } }
      );
    }
  }

  async function newestSucceededBackup(): Promise<{ completed: string; destination: string } | null> {
    const resp: any = await custom.listNamespacedCustomObject(
      "pxc.percona.com",
      PXC_API_VERSION,
      SOURCE_NS,
      "perconaxtradbclusterbackups"
    );

    const items: Obj[] = (resp.body?.items || []) as Obj[];
    const succeeded = items.filter((it) => asString(it?.status?.state) === "Succeeded");

    if (succeeded.length === 0) return null;

    // Sort by status.completed then creationTimestamp
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
    const body: Obj = {
      apiVersion: "pxc.percona.com/v1",
      kind: "PerconaXtraDBClusterRestore",
      metadata: { name: restoreName, namespace: DEST_NS },
      spec: {
        pxcCluster: DEST_PXC_CLUSTER,
        backupSource: {
          destination,
          storageName: DEST_STORAGE_NAME,
        },
      },
    };

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

  async function waitRestoreSucceeded(restoreName: string, timeoutSeconds: number): Promise<"succeeded" | "failed" | "timeout"> {
    const start = Date.now();
    const timeoutMs = timeoutSeconds * 1000;

    while (!shuttingDown) {
      const state = await getRestoreState(restoreName);

      if (state === "Succeeded") return "succeeded";
      if (state === "Failed" || state === "Error") return "failed";

      if (Date.now() - start > timeoutMs) return "timeout";
      await sleep(10_000);
    }
    return "timeout";
  }

  log(`pxc-auto-restore controller starting. source=${SOURCE_NS} dest=${DEST_NS} destCluster=${DEST_PXC_CLUSTER}`);

  while (!shuttingDown) {
    try {
      if (await restoreInProgress()) {
        log(`Restore already in progress in ${DEST_NS}; sleeping ${SLEEP_SECONDS}`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const newest = await newestSucceededBackup();
      if (!newest) {
        log(`No Succeeded backup found in ${SOURCE_NS}; sleeping ${SLEEP_SECONDS}`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const newestCompleted = newest.completed;
      const newestDestination = newest.destination;

      if (!newestDestination) {
        log(`Newest backup has empty .status.destination; cannot restore-to-new-cluster; sleeping ${SLEEP_SECONDS}`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const { lastCompleted, lastDestination } = await getLastRestoreRecord();

      const alreadyRestored =
        lastCompleted &&
        lastCompleted === newestCompleted &&
        lastDestination === newestDestination;

      if (alreadyRestored) {
        log(`Already restored latest backup (completed=${newestCompleted}); sleeping ${SLEEP_SECONDS}`);
        await sleep(SLEEP_SECONDS * 1000);
        continue;
      }

      const restoreName = `auto-restore-${new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}`;
      log(`Triggering restore ${restoreName} from destination=${newestDestination} (completed=${newestCompleted})`);

      await createRestoreCR(restoreName, newestDestination);

      const result = await waitRestoreSucceeded(restoreName, 7200);
      if (result === "succeeded") {
        log(`Restore succeeded: ${restoreName}; recording completed=${newestCompleted} destination=${newestDestination}`);
        await setLastRestoreRecord(newestCompleted, newestDestination);
      } else {
        log(`Restore did not succeed (name=${restoreName}, result=${result}). Will retry on next loop.`);
      }
    } catch (e: any) {
      // Don’t crash the controller; log and keep going
      log(`ERROR: ${e?.message || e}`);
    }

    await sleep(SLEEP_SECONDS * 1000);
  }

  process.exit(0);
}

main().catch((e) => {
  log(`FATAL: ${e?.message || e}`);
  process.exit(1);
});


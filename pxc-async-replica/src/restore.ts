import type * as k8s from "@kubernetes/client-node";
import type { Obj } from "./types";
import { formatK8sError } from "./k8s-errors";
import { log, sleep } from "./log";
import { getPxcSpec } from "./replication";
import { isPxcClusterReadyBody } from "./pxc-cluster-ready";
import { matchesRunningRestoreState, parseS3Bucket } from "./restore-pure";

export { matchesRunningRestoreState, parseS3Bucket } from "./restore-pure";

export async function restoreInProgress(custom: k8s.CustomObjectsApi, args: { pxcApiVersion: string; ns: string }): Promise<boolean> {
  const resp = (await custom.listNamespacedCustomObject({
    group: "pxc.percona.com",
    version: args.pxcApiVersion,
    namespace: args.ns,
    plural: "perconaxtradbclusterrestores",
  })) as { items?: Obj[] };
  const items: Obj[] = (resp.items ?? []) as Obj[];
  for (const it of items) {
    const status = it.status as Obj | undefined;
    const state = typeof status?.state === "string" ? status.state : "";
    if (matchesRunningRestoreState(state)) return true;
  }
  return false;
}

export async function createRestoreFromS3Destination(
  custom: k8s.CustomObjectsApi,
  args: {
    pxcApiVersion: string;
    ns: string;
    cluster: string;
    restoreName: string;
    destination: string;
    s3: { credentialsSecret: string; region: string; endpointUrl: string; forcePathStyle?: boolean };
  }
): Promise<void> {
  const bucket = parseS3Bucket(args.destination);

  const body: Obj = {
    apiVersion: "pxc.percona.com/v1",
    kind: "PerconaXtraDBClusterRestore",
    metadata: { name: args.restoreName, namespace: args.ns },
    spec: {
      pxcCluster: args.cluster,
      backupSource: {
        destination: args.destination,
        s3: {
          bucket,
          credentialsSecret: args.s3.credentialsSecret,
          region: args.s3.region,
          endpointUrl: args.s3.endpointUrl,
          ...(args.s3.forcePathStyle ? { forcePathStyle: true } : {}),
        },
      },
    },
  };

  log(`Creating restore CR ${args.restoreName} in ns=${args.ns} from destination=${args.destination}`);
  await custom.createNamespacedCustomObject({
    group: "pxc.percona.com",
    version: args.pxcApiVersion,
    namespace: args.ns,
    plural: "perconaxtradbclusterrestores",
    body,
  });
}

export async function getRestoreState(custom: k8s.CustomObjectsApi, args: { pxcApiVersion: string; ns: string; restoreName: string }): Promise<string> {
  try {
    const resp = (await custom.getNamespacedCustomObject({
      group: "pxc.percona.com",
      version: args.pxcApiVersion,
      namespace: args.ns,
      plural: "perconaxtradbclusterrestores",
      name: args.restoreName,
    })) as { status?: { state?: string } };
    return typeof resp?.status?.state === "string" ? resp.status.state : "";
  } catch {
    return "";
  }
}

export async function waitRestoreSucceededAndClusterReady(args: {
  custom: k8s.CustomObjectsApi;
  pxcApiVersion: string;
  ns: string;
  cluster: string;
  restoreName: string;
  timeoutSeconds: number;
  pollMs: number;
  isShuttingDown: () => boolean;
}): Promise<"succeeded" | "failed" | "timeout"> {
  const start = Date.now();
  const timeoutMs = args.timeoutSeconds * 1000;

  let restoreSucceeded = false;

  while (!args.isShuttingDown()) {
    if (Date.now() - start > timeoutMs) {
      log(`Timeout reached after ${args.timeoutSeconds}s (restore=${args.restoreName})`);
      return "timeout";
    }

    try {
      const state = await getRestoreState(args.custom, {
        pxcApiVersion: args.pxcApiVersion,
        ns: args.ns,
        restoreName: args.restoreName,
      });

      const remainingSeconds = Math.floor((timeoutMs - (Date.now() - start)) / 1000);
      log(`Restore ${args.restoreName} state="${state}" (timeout in ~${remainingSeconds}s)`);

      if (state === "Failed" || state === "Error") {
        return "failed";
      }

      if (state === "Succeeded") {
        if (!restoreSucceeded) {
          log(`Restore ${args.restoreName} reports Succeeded; waiting for PXC cluster ${args.cluster} to be Ready`);
          restoreSucceeded = true;
        }

        const clusterReady = await (async () => {
          try {
            const body = await getPxcSpec(args.custom, {
              pxcApiVersion: args.pxcApiVersion,
              ns: args.ns,
              cluster: args.cluster,
            });
            const statusObj = body?.status as { state?: string; status?: string } | undefined;
            const st = typeof statusObj?.state === "string" ? statusObj.state : "";
            const status = typeof statusObj?.status === "string" ? statusObj.status : "";
            log(`PXC cluster ${args.cluster} status: state="${st}" status="${status}"`);
            return isPxcClusterReadyBody(body);
          } catch (e: unknown) {
            log(`ERROR checking PXC cluster readiness: ${formatK8sError(e)}`);
            return false;
          }
        })();

        if (clusterReady) {
          log(`PXC cluster ${args.cluster} is Ready after restore`);
          return "succeeded";
        }
      }

      await sleep(args.pollMs);
    } catch (e: unknown) {
      log(`ERROR in waitRestoreSucceeded loop: ${formatK8sError(e)}`);
      await sleep(args.pollMs);
    }
  }

  log("Shutdown signal received while waiting for restore");
  return "timeout";
}

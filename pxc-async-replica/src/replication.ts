import type * as k8s from "@kubernetes/client-node";
import type { Obj } from "./types";
import { formatK8sError } from "./k8s-errors";
import { log } from "./log";
import {
  buildDesiredChannels,
  channelsMatchSpec,
  normalizeChannels,
  type ReplicationChannelConnectConfig,
  type SourceEntry,
} from "./channel-normalize";
import { K8S_PATCH_CONTENT_TYPE_OPTIONS } from "./k8s-patch-options";
import { isPxcClusterReadyBody } from "./pxc-cluster-ready";

export { isPxcClusterReadyBody };

export async function getPxcSpec(custom: k8s.CustomObjectsApi, args: { pxcApiVersion: string; ns: string; cluster: string }): Promise<Obj | null> {
  try {
    const resp = await custom.getNamespacedCustomObject({
      group: "pxc.percona.com",
      version: args.pxcApiVersion,
      namespace: args.ns,
      plural: "perconaxtradbclusters",
      name: args.cluster,
    });
    return (resp ?? null) as Obj | null;
  } catch (e: unknown) {
    log(`get cluster failed: ${formatK8sError(e)}`);
    return null;
  }
}

export async function getClusterReady(custom: k8s.CustomObjectsApi, args: { pxcApiVersion: string; ns: string; cluster: string }): Promise<boolean> {
  const body = await getPxcSpec(custom, args);
  return isPxcClusterReadyBody(body);
}

export function buildDesiredReplicationChannels(args: {
  channelName: string;
  sources: SourceEntry[];
  connectConfig: ReplicationChannelConnectConfig;
}): Obj[] {
  return buildDesiredChannels(args.channelName, args.sources, args.connectConfig) as Obj[];
}

export async function patchReplicationChannels(
  custom: k8s.CustomObjectsApi,
  args: { pxcApiVersion: string; ns: string; cluster: string; channels: Obj[] }
): Promise<void> {
  const patchBody = {
    spec: {
      pxc: {
        replicationChannels: args.channels,
      },
    },
  };

  const ch0 = args.channels[0] as Obj | undefined;
  const nSources = Array.isArray(ch0?.sourcesList) ? (ch0.sourcesList as Obj[]).length : 0;
  const cfg = ch0?.configuration;
  log(
    `Patching ${args.cluster} with replicationChannels (${nSources} source host(s) in channel)` +
      (cfg !== undefined && cfg !== null ? ` configuration=${JSON.stringify(cfg)}` : "")
  );

  await custom.patchNamespacedCustomObject(
    {
      group: "pxc.percona.com",
      version: args.pxcApiVersion,
      namespace: args.ns,
      plural: "perconaxtradbclusters",
      name: args.cluster,
      body: patchBody,
    },
    K8S_PATCH_CONTENT_TYPE_OPTIONS
  );

  log("Merge patch applied successfully (replicationChannels)");
}

export async function verifyReplicationChannels(
  custom: k8s.CustomObjectsApi,
  args: { pxcApiVersion: string; ns: string; cluster: string; desired: Obj[]; clusterBody?: Obj | null }
): Promise<boolean> {
  const body = args.clusterBody !== undefined ? args.clusterBody : await getPxcSpec(custom, args);
  if (!body) return false;
  const spec = body.spec as Obj | undefined;
  const pxc = spec?.pxc as Obj | undefined;
  const actual = pxc?.replicationChannels;
  const ok = channelsMatchSpec(actual, args.desired);
  if (ok) {
    log(`VERIFY OK: replicationChannels match desired (${normalizeChannels(actual)})`);
  } else {
    log(`VERIFY FAILED: expected=${normalizeChannels(args.desired)} actual=${normalizeChannels(actual)}`);
  }
  return ok;
}

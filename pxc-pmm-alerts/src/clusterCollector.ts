import * as k8s from "@kubernetes/client-node";
import {
  CLUSTER_METRIC_META,
  buildClusterMetricSamples,
  serializePrometheusExposition,
  type MetricSample,
  type PodInfo,
  type PvcInfo,
  type PxcCluster,
} from "./clusterMetrics";
import { logLine } from "./log";

export const PXC_GROUP = "pxc.percona.com";
export const PXC_VERSION = "v1";
export const PXC_PLURAL = "perconaxtradbclusters";

export interface CrCollectorClient {
  listClusters(namespace: string): Promise<PxcCluster[]>;
  listPods(namespace: string, labelSelector: string): Promise<PodInfo[]>;
  listPvcs(namespace: string, labelSelector: string): Promise<PvcInfo[]>;
}

export interface MetricsExporter {
  /** POST raw Prometheus text exposition to PMM/VictoriaMetrics import endpoint. */
  pushPrometheusText(body: string): Promise<void>;
}

export interface CollectAndPushResult {
  samples: MetricSample[];
  clustersByNamespace: Record<string, number>;
}

export async function collectAndPushOnce(args: {
  client: CrCollectorClient;
  exporter: MetricsExporter;
  namespaces: string[];
  nowMs: number;
  log?: (msg: string) => void;
}): Promise<CollectAndPushResult> {
  const { client, exporter, namespaces, nowMs } = args;
  const log = args.log ?? logLine;

  if (!namespaces.length) {
    throw new Error("collectAndPushOnce: PXC_WATCH_NAMESPACES is empty; nothing to collect");
  }

  const samples: MetricSample[] = [];
  const clustersByNamespace: Record<string, number> = {};
  let totalClusters = 0;

  for (const ns of namespaces) {
    let clusters: PxcCluster[] = [];
    try {
      clusters = await client.listClusters(ns);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`collector: list PerconaXtraDBCluster failed in ns=${ns}: ${msg} (skipping namespace)`);
      clustersByNamespace[ns] = 0;
      continue;
    }
    clustersByNamespace[ns] = clusters.length;
    totalClusters += clusters.length;

    for (const cluster of clusters) {
      const selector = `app.kubernetes.io/instance=${cluster.metadata.name}`;
      let pods: PodInfo[] = [];
      let pvcs: PvcInfo[] = [];
      try {
        pods = await client.listPods(ns, selector);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`collector: list pods failed in ns=${ns} cluster=${cluster.metadata.name}: ${msg}`);
      }
      try {
        pvcs = await client.listPvcs(ns, selector);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`collector: list pvcs failed in ns=${ns} cluster=${cluster.metadata.name}: ${msg}`);
      }
      samples.push(...buildClusterMetricSamples({ cluster, pods, pvcs, nowMs }));
    }
  }

  samples.push({
    name: "pxc_pmm_alerts_collector_heartbeat_seconds",
    labels: {},
    value: Math.floor(nowMs / 1000),
  });
  samples.push({
    name: "pxc_pmm_alerts_clusters_observed",
    labels: {},
    value: totalClusters,
  });

  const text = serializePrometheusExposition(samples, CLUSTER_METRIC_META);
  await exporter.pushPrometheusText(text);

  return { samples, clustersByNamespace };
}

interface KubeListResponse<T> {
  items: T[];
}

interface RawCrItem {
  metadata?: { name?: string; namespace?: string; generation?: number };
  spec?: PxcCluster["spec"];
  status?: PxcCluster["status"];
}

function asPxcCluster(raw: RawCrItem): PxcCluster | undefined {
  const name = raw?.metadata?.name;
  const namespace = raw?.metadata?.namespace;
  if (typeof name !== "string" || typeof namespace !== "string") return undefined;
  return {
    metadata: { name, namespace, generation: raw.metadata?.generation },
    spec: raw.spec,
    status: raw.status,
  };
}

function asPodInfo(raw: k8s.V1Pod): PodInfo | undefined {
  const name = raw?.metadata?.name;
  const namespace = raw?.metadata?.namespace;
  if (typeof name !== "string" || typeof namespace !== "string") return undefined;
  const labels: Record<string, string> = {};
  if (raw.metadata?.labels) {
    for (const [k, v] of Object.entries(raw.metadata.labels)) {
      if (typeof v === "string") labels[k] = v;
    }
  }
  const conditions = (raw.status?.conditions ?? [])
    .filter((c) => typeof c?.type === "string" && typeof c?.status === "string")
    .map((c) => ({ type: c.type as string, status: c.status as string }));
  return {
    metadata: { name, namespace, labels },
    status: { phase: raw.status?.phase, conditions },
  };
}

function asPvcInfo(raw: k8s.V1PersistentVolumeClaim): PvcInfo | undefined {
  const name = raw?.metadata?.name;
  const namespace = raw?.metadata?.namespace;
  if (typeof name !== "string" || typeof namespace !== "string") return undefined;
  const labels: Record<string, string> = {};
  if (raw.metadata?.labels) {
    for (const [k, v] of Object.entries(raw.metadata.labels)) {
      if (typeof v === "string") labels[k] = v;
    }
  }
  return {
    metadata: { name, namespace, labels },
    status: { phase: raw.status?.phase },
  };
}

export function makeKubeCrCollectorClient(args: {
  core: k8s.CoreV1Api;
  customObjects: k8s.CustomObjectsApi;
}): CrCollectorClient {
  const { core, customObjects } = args;
  return {
    async listClusters(namespace: string) {
      const resp = (await customObjects.listNamespacedCustomObject({
        group: PXC_GROUP,
        version: PXC_VERSION,
        namespace,
        plural: PXC_PLURAL,
      })) as KubeListResponse<RawCrItem> | undefined;
      const items = Array.isArray(resp?.items) ? resp!.items : [];
      const out: PxcCluster[] = [];
      for (const it of items) {
        const c = asPxcCluster(it);
        if (c) out.push(c);
      }
      return out;
    },
    async listPods(namespace: string, labelSelector: string) {
      const resp = await core.listNamespacedPod({ namespace, labelSelector });
      const items = Array.isArray(resp?.items) ? resp.items : [];
      const out: PodInfo[] = [];
      for (const it of items) {
        const p = asPodInfo(it);
        if (p) out.push(p);
      }
      return out;
    },
    async listPvcs(namespace: string, labelSelector: string) {
      const resp = await core.listNamespacedPersistentVolumeClaim({ namespace, labelSelector });
      const items = Array.isArray(resp?.items) ? resp.items : [];
      const out: PvcInfo[] = [];
      for (const it of items) {
        const v = asPvcInfo(it);
        if (v) out.push(v);
      }
      return out;
    },
  };
}

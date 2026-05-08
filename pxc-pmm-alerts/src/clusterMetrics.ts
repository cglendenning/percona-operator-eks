/**
 * Pure functions: derive Prometheus-style samples from a PerconaXtraDBCluster CR plus its owned
 * Pods/PVCs, and serialize to the Prometheus text exposition format. Pushed to PMM/VictoriaMetrics
 * via `pmmClient.importPrometheusMetrics` so PromQL alert rules can reason about the operator's
 * view of cluster health, which PMM-scraped mysql_/node_/haproxy_ series cannot expose
 * (status.state=error, paused, pods Pending/PVC unbound, observedGeneration drift).
 */

export interface MetricSample {
  name: string;
  labels: Record<string, string>;
  value: number;
}

export interface MetricMeta {
  help: string;
  type: "gauge" | "counter";
}

export const KNOWN_PXC_STATES = [
  "initializing",
  "applying-changes",
  "paused",
  "ready",
  "error",
  "stopping",
  "unknown",
] as const;

export const POD_PHASES = ["Pending", "Running", "Failed", "Succeeded", "Unknown"] as const;

export interface PxcClusterStatusBlock {
  ready?: number;
  size?: number;
  status?: string;
}

export interface PxcCluster {
  metadata: { name: string; namespace: string; generation?: number };
  spec?: {
    pause?: boolean;
    pxc?: { size?: number };
    haproxy?: { enabled?: boolean; size?: number };
    proxysql?: { enabled?: boolean; size?: number };
  };
  status?: {
    state?: string;
    pxc?: PxcClusterStatusBlock;
    haproxy?: PxcClusterStatusBlock;
    proxysql?: PxcClusterStatusBlock;
    ready?: number;
    size?: number;
    observedGeneration?: number;
    conditions?: Array<{ type?: string; status?: string; lastTransitionTime?: string }>;
  };
}

export interface PodInfo {
  metadata: { name: string; namespace: string; labels?: Record<string, string> };
  status?: {
    phase?: string;
    conditions?: Array<{ type?: string; status?: string }>;
  };
}

export interface PvcInfo {
  metadata: { name: string; namespace: string; labels?: Record<string, string> };
  status?: { phase?: string };
}

const INSTANCE_LABEL = "app.kubernetes.io/instance";
const COMPONENT_LABEL = "app.kubernetes.io/component";

function clusterLabels(cluster: PxcCluster): Record<string, string> {
  return { cluster: cluster.metadata.name, namespace: cluster.metadata.namespace };
}

function classifyState(raw: string | undefined): (typeof KNOWN_PXC_STATES)[number] {
  if (!raw) return "unknown";
  const lower = raw.toLowerCase();
  return (KNOWN_PXC_STATES as readonly string[]).includes(lower)
    ? (lower as (typeof KNOWN_PXC_STATES)[number])
    : "unknown";
}

function newestConditionTimeMs(cluster: PxcCluster): number | undefined {
  const conds = cluster.status?.conditions;
  if (!Array.isArray(conds) || conds.length === 0) return undefined;
  let newest: number | undefined;
  for (const c of conds) {
    const ts = typeof c?.lastTransitionTime === "string" ? Date.parse(c.lastTransitionTime) : NaN;
    if (!Number.isFinite(ts)) continue;
    if (newest === undefined || ts > newest) newest = ts;
  }
  return newest;
}

function nonNegInt(n: number | undefined): number {
  return typeof n === "number" && Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
}

export function buildClusterMetricSamples(args: {
  cluster: PxcCluster;
  pods: PodInfo[];
  pvcs: PvcInfo[];
  nowMs: number;
}): MetricSample[] {
  const { cluster, pods, pvcs, nowMs } = args;
  const base = clusterLabels(cluster);
  const out: MetricSample[] = [];

  const state = classifyState(cluster.status?.state);
  out.push({ name: "pxc_cluster_ready", labels: base, value: state === "ready" ? 1 : 0 });

  for (const candidate of KNOWN_PXC_STATES) {
    out.push({
      name: "pxc_cluster_state",
      labels: { ...base, state: candidate },
      value: state === candidate ? 1 : 0,
    });
  }

  out.push({
    name: "pxc_cluster_paused",
    labels: base,
    value: cluster.spec?.pause === true ? 1 : 0,
  });

  out.push({
    name: "pxc_cluster_generation",
    labels: base,
    value: nonNegInt(cluster.metadata.generation),
  });
  out.push({
    name: "pxc_cluster_observed_generation",
    labels: base,
    value: nonNegInt(cluster.status?.observedGeneration),
  });

  const newest = newestConditionTimeMs(cluster);
  out.push({
    name: "pxc_cluster_last_transition_age_seconds",
    labels: base,
    value: newest === undefined ? 0 : Math.max(0, Math.round((nowMs - newest) / 1000)),
  });

  out.push({
    name: "pxc_pxc_ready",
    labels: base,
    value: nonNegInt(cluster.status?.pxc?.ready),
  });
  out.push({
    name: "pxc_pxc_size",
    labels: base,
    value: nonNegInt(cluster.status?.pxc?.size ?? cluster.spec?.pxc?.size),
  });

  if (cluster.spec?.haproxy?.enabled === true) {
    out.push({
      name: "pxc_haproxy_ready",
      labels: base,
      value: nonNegInt(cluster.status?.haproxy?.ready),
    });
    out.push({
      name: "pxc_haproxy_size",
      labels: base,
      value: nonNegInt(cluster.status?.haproxy?.size ?? cluster.spec?.haproxy?.size),
    });
  }

  if (cluster.spec?.proxysql?.enabled === true) {
    out.push({
      name: "pxc_proxysql_ready",
      labels: base,
      value: nonNegInt(cluster.status?.proxysql?.ready),
    });
    out.push({
      name: "pxc_proxysql_size",
      labels: base,
      value: nonNegInt(cluster.status?.proxysql?.size ?? cluster.spec?.proxysql?.size),
    });
  }

  for (const p of pods) {
    const labels = p.metadata.labels ?? {};
    if (labels[INSTANCE_LABEL] !== cluster.metadata.name) continue;
    const role = labels[COMPONENT_LABEL] || "unknown";
    const podBase = { ...base, pod: p.metadata.name, role };
    const cond = (p.status?.conditions ?? []).find((c) => c?.type === "Ready");
    out.push({
      name: "pxc_pod_ready",
      labels: podBase,
      value: cond?.status === "True" ? 1 : 0,
    });
    const phase = typeof p.status?.phase === "string" && (POD_PHASES as readonly string[]).includes(p.status.phase)
      ? p.status.phase
      : "Unknown";
    for (const candidate of POD_PHASES) {
      out.push({
        name: "pxc_pod_phase",
        labels: { ...podBase, phase: candidate },
        value: phase === candidate ? 1 : 0,
      });
    }
  }

  for (const v of pvcs) {
    const labels = v.metadata.labels ?? {};
    if (labels[INSTANCE_LABEL] !== cluster.metadata.name) continue;
    const role = labels[COMPONENT_LABEL] || "unknown";
    out.push({
      name: "pxc_pvc_pending",
      labels: { ...base, pvc: v.metadata.name, role },
      value: v.status?.phase === "Bound" ? 0 : 1,
    });
  }

  return out;
}

function escapeLabelValue(v: string): string {
  return v.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/"/g, '\\"');
}

function renderLabels(labels: Record<string, string>): string {
  const keys = Object.keys(labels).sort();
  if (keys.length === 0) return "";
  const inner = keys.map((k) => `${k}="${escapeLabelValue(labels[k] ?? "")}"`).join(",");
  return `{${inner}}`;
}

export function serializePrometheusExposition(
  samples: MetricSample[],
  meta: Record<string, MetricMeta> = {}
): string {
  const byName = new Map<string, MetricSample[]>();
  for (const s of samples) {
    if (!Number.isFinite(s.value)) continue;
    const arr = byName.get(s.name) ?? [];
    arr.push(s);
    byName.set(s.name, arr);
  }
  const names = Array.from(byName.keys()).sort();
  const lines: string[] = [];
  for (const name of names) {
    const m = meta[name];
    if (m) {
      lines.push(`# HELP ${name} ${m.help}`);
      lines.push(`# TYPE ${name} ${m.type}`);
    }
    const rows = byName.get(name) ?? [];
    for (const s of rows) {
      lines.push(`${name}${renderLabels(s.labels)} ${s.value}`);
    }
  }
  return lines.length === 0 ? "" : `${lines.join("\n")}\n`;
}

export const CLUSTER_METRIC_META: Record<string, MetricMeta> = {
  pxc_cluster_ready: {
    help: "1 if PerconaXtraDBCluster .status.state == ready, else 0.",
    type: "gauge",
  },
  pxc_cluster_state: {
    help: "1 for the cluster's active operator-reported .status.state, 0 for inactive states.",
    type: "gauge",
  },
  pxc_cluster_paused: {
    help: "1 when .spec.pause is true.",
    type: "gauge",
  },
  pxc_cluster_generation: {
    help: ".metadata.generation observed on the cluster object.",
    type: "gauge",
  },
  pxc_cluster_observed_generation: {
    help: ".status.observedGeneration last reconciled by the operator.",
    type: "gauge",
  },
  pxc_cluster_last_transition_age_seconds: {
    help: "Seconds since the newest .status.conditions[].lastTransitionTime.",
    type: "gauge",
  },
  pxc_pxc_ready: { help: ".status.pxc.ready replica count.", type: "gauge" },
  pxc_pxc_size: { help: "Desired pxc replica count (status.pxc.size, falls back to spec.pxc.size).", type: "gauge" },
  pxc_haproxy_ready: { help: ".status.haproxy.ready replica count.", type: "gauge" },
  pxc_haproxy_size: { help: "Desired haproxy replica count.", type: "gauge" },
  pxc_proxysql_ready: { help: ".status.proxysql.ready replica count.", type: "gauge" },
  pxc_proxysql_size: { help: "Desired proxysql replica count.", type: "gauge" },
  pxc_pod_ready: { help: "1 if the pod's Ready condition is True, else 0.", type: "gauge" },
  pxc_pod_phase: { help: "1 for the pod's current .status.phase, 0 for the rest.", type: "gauge" },
  pxc_pvc_pending: { help: "1 if PVC .status.phase != Bound.", type: "gauge" },
  pxc_pmm_alerts_collector_heartbeat_seconds: {
    help: "Unix epoch seconds of the controller's most recent successful collect+push.",
    type: "gauge",
  },
  pxc_pmm_alerts_clusters_observed: {
    help: "Count of PerconaXtraDBCluster CRs observed in the last successful collect cycle.",
    type: "gauge",
  },
};

import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./log", () => ({ logLine: vi.fn() }));

import { logLine } from "./log";
import { collectAndPushOnce, type CrCollectorClient, type MetricsExporter } from "./clusterCollector";
import type { PodInfo, PvcInfo, PxcCluster } from "./clusterMetrics";

const NS = "percona";
const CLUSTER = "db";
const NOW_MS = 1_700_000_000_000;

function readyCluster(name: string = CLUSTER, ns: string = NS): PxcCluster {
  return {
    metadata: { name, namespace: ns, generation: 3 },
    spec: { pxc: { size: 3 }, haproxy: { enabled: true, size: 2 } },
    status: {
      state: "ready",
      pxc: { ready: 3, size: 3 },
      haproxy: { ready: 2, size: 2 },
      observedGeneration: 3,
    },
  };
}

function fakeClient(overrides: Partial<CrCollectorClient> = {}): CrCollectorClient & { trace: string[] } {
  const trace: string[] = [];
  return {
    trace,
    listClusters: async (ns) => {
      trace.push(`listClusters:${ns}`);
      return overrides.listClusters ? await overrides.listClusters(ns) : [];
    },
    listPods: async (ns, sel) => {
      trace.push(`listPods:${ns}:${sel}`);
      return overrides.listPods ? await overrides.listPods(ns, sel) : [];
    },
    listPvcs: async (ns, sel) => {
      trace.push(`listPvcs:${ns}:${sel}`);
      return overrides.listPvcs ? await overrides.listPvcs(ns, sel) : [];
    },
  };
}

function fakeExporter(): MetricsExporter & { pushed: string[] } {
  const pushed: string[] = [];
  return {
    pushed,
    pushPrometheusText: async (body) => {
      pushed.push(body);
    },
  };
}

beforeEach(() => {
  vi.mocked(logLine).mockClear();
});

describe("collectAndPushOnce", () => {
  it("lists clusters/pods/pvcs in each namespace and pushes a single body", async () => {
    const client = fakeClient({
      listClusters: async (ns) => (ns === NS ? [readyCluster()] : []),
      listPods: async (ns) =>
        ns === NS
          ? [
              {
                metadata: {
                  name: "db-pxc-0",
                  namespace: NS,
                  labels: {
                    "app.kubernetes.io/instance": CLUSTER,
                    "app.kubernetes.io/component": "pxc",
                  },
                },
                status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] },
              } satisfies PodInfo,
            ]
          : [],
      listPvcs: async (ns) =>
        ns === NS
          ? [
              {
                metadata: {
                  name: "datadir-db-pxc-0",
                  namespace: NS,
                  labels: {
                    "app.kubernetes.io/instance": CLUSTER,
                    "app.kubernetes.io/component": "pxc",
                  },
                },
                status: { phase: "Bound" },
              } satisfies PvcInfo,
            ]
          : [],
    });
    const exporter = fakeExporter();
    const result = await collectAndPushOnce({
      client,
      exporter,
      namespaces: [NS, "empty"],
      nowMs: NOW_MS,
    });
    expect(result.clustersByNamespace).toEqual({ [NS]: 1, empty: 0 });
    expect(client.trace.filter((t) => t.startsWith("listClusters:"))).toEqual([
      `listClusters:${NS}`,
      "listClusters:empty",
    ]);
    expect(exporter.pushed.length).toBe(1);
    const text = exporter.pushed[0];
    expect(text).toContain('pxc_cluster_ready{cluster="db",namespace="percona"} 1');
    expect(text).toContain('pxc_pod_ready{cluster="db",namespace="percona",pod="db-pxc-0",role="pxc"} 1');
    expect(text).toContain(
      'pxc_pvc_pending{cluster="db",namespace="percona",pvc="datadir-db-pxc-0",role="pxc"} 0'
    );
    expect(text).toMatch(/pxc_pmm_alerts_collector_heartbeat_seconds 1700000000\b/);
    expect(text).toContain("pxc_pmm_alerts_clusters_observed 1");
  });

  it("uses labelSelector app.kubernetes.io/instance to scope pods/pvcs to the cluster", async () => {
    const client = fakeClient({
      listClusters: async () => [readyCluster()],
    });
    const exporter = fakeExporter();
    await collectAndPushOnce({ client, exporter, namespaces: [NS], nowMs: NOW_MS });
    const podsListed = client.trace.find((t) => t.startsWith(`listPods:${NS}:`));
    const pvcsListed = client.trace.find((t) => t.startsWith(`listPvcs:${NS}:`));
    expect(podsListed).toContain("app.kubernetes.io/instance=db");
    expect(pvcsListed).toContain("app.kubernetes.io/instance=db");
  });

  it("skips namespaces whose CRD list throws (404 / forbidden) and continues with the rest", async () => {
    const client = fakeClient({
      listClusters: async (ns) => {
        if (ns === "missing") throw new Error("CRD not installed");
        return [readyCluster("db2", ns)];
      },
    });
    const exporter = fakeExporter();
    const result = await collectAndPushOnce({
      client,
      exporter,
      namespaces: ["missing", NS],
      nowMs: NOW_MS,
    });
    expect(result.clustersByNamespace).toEqual({ missing: 0, [NS]: 1 });
    expect(exporter.pushed.length).toBe(1);
    expect(exporter.pushed[0]).toContain('pxc_cluster_ready{cluster="db2",namespace="percona"} 1');
    expect(vi.mocked(logLine).mock.calls.some((c) => String(c[0]).includes("missing"))).toBe(true);
  });

  it("still pushes a heartbeat-only body when no clusters exist anywhere", async () => {
    const client = fakeClient();
    const exporter = fakeExporter();
    const result = await collectAndPushOnce({ client, exporter, namespaces: [NS], nowMs: NOW_MS });
    expect(result.clustersByNamespace).toEqual({ [NS]: 0 });
    expect(exporter.pushed.length).toBe(1);
    expect(exporter.pushed[0]).toContain("pxc_pmm_alerts_collector_heartbeat_seconds");
    expect(exporter.pushed[0]).toContain("pxc_pmm_alerts_clusters_observed 0");
    expect(exporter.pushed[0]).not.toContain("pxc_cluster_ready");
  });

  it("skips push and bubbles error when exporter.pushPrometheusText throws", async () => {
    const client = fakeClient({ listClusters: async () => [readyCluster()] });
    const exporter: MetricsExporter = {
      pushPrometheusText: async () => {
        throw new Error("import 503");
      },
    };
    await expect(
      collectAndPushOnce({ client, exporter, namespaces: [NS], nowMs: NOW_MS })
    ).rejects.toThrow(/import 503/);
  });

  it("rejects empty namespace list with a clear error", async () => {
    const client = fakeClient();
    const exporter = fakeExporter();
    await expect(
      collectAndPushOnce({ client, exporter, namespaces: [], nowMs: NOW_MS })
    ).rejects.toThrow(/PXC_WATCH_NAMESPACES/);
  });
});

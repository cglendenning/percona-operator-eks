import { describe, expect, it } from "vitest";
import {
  KNOWN_PXC_STATES,
  POD_PHASES,
  buildClusterMetricSamples,
  serializePrometheusExposition,
  type MetricSample,
  type PodInfo,
  type PvcInfo,
  type PxcCluster,
} from "./clusterMetrics";

const NS = "percona";
const CLUSTER = "db";
const NOW_MS = 1_700_000_000_000;

function findSample(samples: MetricSample[], name: string, labels: Record<string, string> = {}): MetricSample | undefined {
  return samples.find((s) => {
    if (s.name !== name) return false;
    for (const [k, v] of Object.entries(labels)) {
      if (s.labels[k] !== v) return false;
    }
    return true;
  });
}

function findAll(samples: MetricSample[], name: string): MetricSample[] {
  return samples.filter((s) => s.name === name);
}

function readyCluster(overrides: Partial<PxcCluster> = {}): PxcCluster {
  return {
    metadata: { name: CLUSTER, namespace: NS, generation: 7 },
    spec: {
      pxc: { size: 3 },
      haproxy: { enabled: true, size: 2 },
      proxysql: { enabled: false, size: 0 },
    },
    status: {
      state: "ready",
      pxc: { ready: 3, size: 3, status: "ready" },
      haproxy: { ready: 2, size: 2, status: "ready" },
      ready: 5,
      size: 5,
      observedGeneration: 7,
      conditions: [
        {
          type: "PXCReady",
          status: "True",
          lastTransitionTime: new Date(NOW_MS - 60_000).toISOString(),
        },
      ],
    },
    ...overrides,
  };
}

function pod(name: string, role: string, ready: boolean, phase: string = ready ? "Running" : "Pending"): PodInfo {
  return {
    metadata: {
      name,
      namespace: NS,
      labels: {
        "app.kubernetes.io/instance": CLUSTER,
        "app.kubernetes.io/component": role,
      },
    },
    status: {
      phase,
      conditions: [{ type: "Ready", status: ready ? "True" : "False" }],
    },
  };
}

function pvc(name: string, phase: string, role: string = "pxc"): PvcInfo {
  return {
    metadata: {
      name,
      namespace: NS,
      labels: {
        "app.kubernetes.io/instance": CLUSTER,
        "app.kubernetes.io/component": role,
      },
    },
    status: { phase },
  };
}

describe("buildClusterMetricSamples (cluster status)", () => {
  it("emits pxc_cluster_ready=1 for status.state=ready", () => {
    const samples = buildClusterMetricSamples({ cluster: readyCluster(), pods: [], pvcs: [], nowMs: NOW_MS });
    const ready = findSample(samples, "pxc_cluster_ready", { cluster: CLUSTER, namespace: NS });
    expect(ready?.value).toBe(1);
  });

  it("emits pxc_cluster_ready=0 for any non-ready state", () => {
    for (const state of ["initializing", "applying-changes", "error", "paused", "stopping"]) {
      const samples = buildClusterMetricSamples({
        cluster: readyCluster({ status: { ...readyCluster().status, state } }),
        pods: [],
        pvcs: [],
        nowMs: NOW_MS,
      });
      const ready = findSample(samples, "pxc_cluster_ready", { cluster: CLUSTER, namespace: NS });
      expect(ready?.value, `state=${state}`).toBe(0);
    }
  });

  it("emits one pxc_cluster_state series per known state with 1 only on the active state", () => {
    const samples = buildClusterMetricSamples({
      cluster: readyCluster({ status: { state: "error" } }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    const states = findAll(samples, "pxc_cluster_state");
    expect(states.length).toBe(KNOWN_PXC_STATES.length);
    for (const s of states) {
      expect(s.labels.cluster).toBe(CLUSTER);
      expect(s.labels.namespace).toBe(NS);
      expect(KNOWN_PXC_STATES).toContain(s.labels.state as (typeof KNOWN_PXC_STATES)[number]);
      expect(s.value).toBe(s.labels.state === "error" ? 1 : 0);
    }
  });

  it("maps unknown / missing status.state to state=\"unknown\"", () => {
    const samples = buildClusterMetricSamples({
      cluster: { metadata: { name: CLUSTER, namespace: NS } },
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    const unknown = findSample(samples, "pxc_cluster_state", { state: "unknown" });
    expect(unknown?.value).toBe(1);
    const ready = findSample(samples, "pxc_cluster_state", { state: "ready" });
    expect(ready?.value).toBe(0);
  });

  it("emits pxc_cluster_paused=1 only when spec.pause is true", () => {
    const off = buildClusterMetricSamples({ cluster: readyCluster(), pods: [], pvcs: [], nowMs: NOW_MS });
    expect(findSample(off, "pxc_cluster_paused")?.value).toBe(0);
    const on = buildClusterMetricSamples({
      cluster: readyCluster({ spec: { ...readyCluster().spec, pause: true } }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    expect(findSample(on, "pxc_cluster_paused")?.value).toBe(1);
  });

  it("emits pxc_pxc_ready and pxc_pxc_size from .status.pxc", () => {
    const samples = buildClusterMetricSamples({
      cluster: readyCluster({ status: { ...readyCluster().status, pxc: { ready: 2, size: 3 } } }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    expect(findSample(samples, "pxc_pxc_ready")?.value).toBe(2);
    expect(findSample(samples, "pxc_pxc_size")?.value).toBe(3);
  });

  it("falls back to .spec.pxc.size when .status.pxc.size missing", () => {
    const samples = buildClusterMetricSamples({
      cluster: readyCluster({ status: { state: "initializing" } }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    expect(findSample(samples, "pxc_pxc_size")?.value).toBe(3);
    expect(findSample(samples, "pxc_pxc_ready")?.value).toBe(0);
  });

  it("emits haproxy metrics only when spec.haproxy.enabled=true", () => {
    const enabled = buildClusterMetricSamples({ cluster: readyCluster(), pods: [], pvcs: [], nowMs: NOW_MS });
    expect(findSample(enabled, "pxc_haproxy_ready")?.value).toBe(2);
    expect(findSample(enabled, "pxc_haproxy_size")?.value).toBe(2);

    const disabled = buildClusterMetricSamples({
      cluster: readyCluster({ spec: { pxc: { size: 3 }, haproxy: { enabled: false } } }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    expect(findSample(disabled, "pxc_haproxy_ready")).toBeUndefined();
    expect(findSample(disabled, "pxc_haproxy_size")).toBeUndefined();
  });

  it("emits proxysql metrics only when spec.proxysql.enabled=true", () => {
    const samples = buildClusterMetricSamples({
      cluster: readyCluster({
        spec: { pxc: { size: 3 }, haproxy: { enabled: false }, proxysql: { enabled: true, size: 3 } },
        status: { state: "ready", proxysql: { ready: 3, size: 3 } },
      }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    expect(findSample(samples, "pxc_proxysql_ready")?.value).toBe(3);
    expect(findSample(samples, "pxc_proxysql_size")?.value).toBe(3);
  });

  it("emits observedGeneration and metadata.generation as gauges", () => {
    const samples = buildClusterMetricSamples({ cluster: readyCluster(), pods: [], pvcs: [], nowMs: NOW_MS });
    expect(findSample(samples, "pxc_cluster_generation")?.value).toBe(7);
    expect(findSample(samples, "pxc_cluster_observed_generation")?.value).toBe(7);
  });

  it("emits pxc_cluster_last_transition_age_seconds derived from latest condition", () => {
    const samples = buildClusterMetricSamples({ cluster: readyCluster(), pods: [], pvcs: [], nowMs: NOW_MS });
    const age = findSample(samples, "pxc_cluster_last_transition_age_seconds");
    expect(age?.value).toBe(60);
  });

  it("uses 0 last_transition_age when conditions missing", () => {
    const samples = buildClusterMetricSamples({
      cluster: readyCluster({ status: { state: "ready" } }),
      pods: [],
      pvcs: [],
      nowMs: NOW_MS,
    });
    expect(findSample(samples, "pxc_cluster_last_transition_age_seconds")?.value).toBe(0);
  });
});

describe("buildClusterMetricSamples (pods)", () => {
  it("emits pxc_pod_ready=1 when Ready cond is True, 0 otherwise", () => {
    const pods = [pod("db-pxc-0", "pxc", true), pod("db-pxc-1", "pxc", false)];
    const samples = buildClusterMetricSamples({ cluster: readyCluster(), pods, pvcs: [], nowMs: NOW_MS });
    expect(findSample(samples, "pxc_pod_ready", { pod: "db-pxc-0", role: "pxc" })?.value).toBe(1);
    expect(findSample(samples, "pxc_pod_ready", { pod: "db-pxc-1", role: "pxc" })?.value).toBe(0);
  });

  it("emits one pxc_pod_phase per known phase with 1 on the active phase", () => {
    const pods = [pod("db-pxc-0", "pxc", false, "Pending")];
    const samples = buildClusterMetricSamples({ cluster: readyCluster(), pods, pvcs: [], nowMs: NOW_MS });
    const phaseSamples = findAll(samples, "pxc_pod_phase").filter((s) => s.labels.pod === "db-pxc-0");
    expect(phaseSamples.length).toBe(POD_PHASES.length);
    for (const ph of phaseSamples) {
      expect(ph.value).toBe(ph.labels.phase === "Pending" ? 1 : 0);
    }
  });

  it("treats pods without app.kubernetes.io/instance label as unrelated and skips them", () => {
    const orphan: PodInfo = { metadata: { name: "stranger", namespace: NS, labels: {} } };
    const samples = buildClusterMetricSamples({ cluster: readyCluster(), pods: [orphan], pvcs: [], nowMs: NOW_MS });
    expect(findAll(samples, "pxc_pod_ready").length).toBe(0);
  });
});

describe("buildClusterMetricSamples (pvcs)", () => {
  it("emits pxc_pvc_pending=1 for non-Bound, =0 for Bound", () => {
    const samples = buildClusterMetricSamples({
      cluster: readyCluster(),
      pods: [],
      pvcs: [pvc("datadir-db-pxc-0", "Bound"), pvc("datadir-db-pxc-1", "Pending")],
      nowMs: NOW_MS,
    });
    expect(findSample(samples, "pxc_pvc_pending", { pvc: "datadir-db-pxc-0" })?.value).toBe(0);
    expect(findSample(samples, "pxc_pvc_pending", { pvc: "datadir-db-pxc-1" })?.value).toBe(1);
  });
});

describe("serializePrometheusExposition", () => {
  it("emits HELP, TYPE, and one line per sample", () => {
    const samples: MetricSample[] = [
      { name: "pxc_cluster_ready", labels: { cluster: "db", namespace: "percona" }, value: 1 },
      { name: "pxc_cluster_ready", labels: { cluster: "db2", namespace: "percona" }, value: 0 },
    ];
    const text = serializePrometheusExposition(samples, {
      pxc_cluster_ready: { help: "1 if status.state==ready", type: "gauge" },
    });
    expect(text).toContain("# HELP pxc_cluster_ready 1 if status.state==ready");
    expect(text).toContain("# TYPE pxc_cluster_ready gauge");
    expect(text).toContain('pxc_cluster_ready{cluster="db",namespace="percona"} 1');
    expect(text).toContain('pxc_cluster_ready{cluster="db2",namespace="percona"} 0');
    expect(text.endsWith("\n")).toBe(true);
  });

  it("renders no-label samples without braces", () => {
    const text = serializePrometheusExposition(
      [{ name: "pxc_pmm_alerts_collector_heartbeat_seconds", labels: {}, value: 1700000000 }],
      { pxc_pmm_alerts_collector_heartbeat_seconds: { help: "h", type: "gauge" } }
    );
    expect(text).toContain("pxc_pmm_alerts_collector_heartbeat_seconds 1700000000\n");
  });

  it("escapes backslash, double quote, and newline in label values", () => {
    const text = serializePrometheusExposition(
      [{ name: "x", labels: { v: 'a"b\\c\nd' }, value: 1 }],
      { x: { help: "h", type: "gauge" } }
    );
    expect(text).toContain('x{v="a\\"b\\\\c\\nd"} 1');
  });

  it("orders labels alphabetically and groups by metric name", () => {
    const text = serializePrometheusExposition(
      [
        { name: "b", labels: { z: "1", a: "2" }, value: 1 },
        { name: "a", labels: {}, value: 0 },
      ],
      {}
    );
    const aIdx = text.indexOf("a 0");
    const bIdx = text.indexOf('b{a="2",z="1"} 1');
    expect(aIdx).toBe(0);
    expect(bIdx).toBeGreaterThan(aIdx);
  });

  it("skips samples whose value is not a finite number", () => {
    const text = serializePrometheusExposition(
      [
        { name: "a", labels: {}, value: Number.NaN },
        { name: "b", labels: {}, value: 1 },
      ],
      {}
    );
    expect(text).not.toContain("a ");
    expect(text).toContain("b 1");
  });
});

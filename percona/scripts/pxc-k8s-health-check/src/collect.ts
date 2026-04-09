import { KubectlError, kubectlJson, kubectlText } from "./kubectl";
import type { Finding } from "./types";

type K8sList<T> = { items?: T[] };

type Pod = {
  metadata?: { name?: string; namespace?: string; labels?: Record<string, string> };
  status?: {
    phase?: string;
    containerStatuses?: {
      name?: string;
      ready?: boolean;
      restartCount?: number;
      state?: Record<string, unknown>;
    }[];
    conditions?: { type?: string; status?: string; reason?: string; message?: string }[];
  };
};

type PXC = {
  metadata?: { name?: string; creationTimestamp?: string };
  spec?: {
    crVersion?: string;
    pxc?: { size?: number; image?: string };
    haproxy?: { enabled?: boolean; size?: number; image?: string };
    proxysql?: { enabled?: boolean; size?: number };
  };
  status?: {
    state?: string;
    message?: string;
    ready?: string;
    size?: number;
    pxc?: { image?: string; ready?: number; size?: number; version?: string };
    haproxy?: { image?: string; ready?: number; size?: number };
  };
};

type Service = {
  metadata?: { name?: string; labels?: Record<string, string> };
  spec?: { clusterIP?: string; selector?: Record<string, string>; ports?: { port?: number }[] };
};

type EndpointSubset = {
  addresses?: { ip?: string; targetRef?: { name?: string } }[];
  notReadyAddresses?: { ip?: string; targetRef?: { name?: string } }[];
};

type Endpoints = {
  metadata?: { name?: string };
  subsets?: EndpointSubset[];
};

type PVC = {
  metadata?: { name?: string };
  status?: { phase?: string };
};

type NetworkPolicy = { metadata?: { name?: string } };

type Event = {
  type?: string;
  reason?: string;
  message?: string;
  involvedObject?: { kind?: string; name?: string };
  lastTimestamp?: string;
  count?: number;
};

export async function collectFindings(ns: string): Promise<Finding[]> {
  const findings: Finding[] = [];

  const add = (f: Finding) => findings.push(f);

  // Namespace
  try {
    await kubectlJson(["get", "namespace", ns]);
    add({
      severity: "ok",
      code: "NS_EXISTS",
      title: "Namespace exists",
      detail: ns,
    });
  } catch (e: unknown) {
    add({
      severity: "fail",
      code: "NS_MISSING",
      title: "Namespace not found or inaccessible",
      detail: e instanceof Error ? e.message : String(e),
    });
    return findings;
  }

  // CRD / PXC list
  let pxcItems: PXC[] = [];
  try {
    const list = await kubectlJson<K8sList<PXC>>(
      ["get", "perconaxtradbclusters.pxc.percona.com"],
      ns
    );
    pxcItems = list.items ?? [];
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    add({
      severity: "fail",
      code: "PXC_CRD_OR_API",
      title: "Cannot list PerconaXtraDBCluster resources",
      detail: msg,
    });
    add({
      severity: "info",
      code: "HINT_CRD",
      title: "Hint",
      detail:
        "Ensure Percona PXC operator is installed and your kube user can read pxc.percona.com in this namespace.",
    });
  }

  if (pxcItems.length === 0) {
    add({
      severity: "warn",
      code: "NO_PXC_CR",
      title: "No PerconaXtraDBCluster custom resource in namespace",
      detail: "Expected at least one cluster CR for a PXC deployment.",
    });
  }

  for (const cr of pxcItems) {
    const name = cr.metadata?.name ?? "?";
    const state = cr.status?.state ?? "";
    const message = cr.status?.message ?? "";
    const sev: Finding["severity"] =
      state === "ready"
        ? "ok"
        : state === "error" || state === "failed"
          ? "fail"
          : "warn";
    add({
      severity: sev,
      code: "PXC_STATUS",
      title: `PXC CR "${name}" status.state=${state || "(empty)"}`,
      detail: message || "(no status.message)",
    });

    const pxcReady = cr.status?.pxc?.ready;
    const pxcSize = cr.status?.pxc?.size ?? cr.spec?.pxc?.size;
    if (pxcSize != null && pxcReady != null && pxcReady < pxcSize) {
      add({
        severity: "warn",
        code: "PXC_NOT_FULLY_READY",
        title: `PXC data nodes ready ${pxcReady}/${pxcSize} (${name})`,
        detail: "HAProxy and operator traffic depend on healthy PXC pods.",
      });
    }

    const haEnabled = cr.spec?.haproxy?.enabled !== false;
    if (haEnabled) {
      const haReady = cr.status?.haproxy?.ready;
      const haSize = cr.spec?.haproxy?.size;
      if (haSize != null && haReady != null && haReady < haSize) {
        add({
          severity: "fail",
          code: "HAPROXY_NOT_READY",
          title: `HAProxy ready ${haReady}/${haSize} (${name})`,
          detail:
            "Operator often reaches MySQL via HAProxy; not ready can cause 'proxy connection refused'.",
        });
      }
    }
  }

  // Pods
  let pods: Pod[] = [];
  try {
    const pl = await kubectlJson<K8sList<Pod>>(["get", "pods"], ns);
    pods = pl.items ?? [];
  } catch (e: unknown) {
    add({
      severity: "fail",
      code: "PODS_LIST",
      title: "Cannot list pods",
      detail: e instanceof Error ? e.message : String(e),
    });
  }

  const nameMatches = (n: string, re: RegExp) => re.test(n);
  const pxcPods = pods.filter((p) =>
    nameMatches(p.metadata?.name ?? "", /-pxc-\d+$/i)
  );
  const haPods = pods.filter((p) =>
    nameMatches(p.metadata?.name ?? "", /-haproxy-/i)
  );

  for (const p of pxcPods) {
    const n = p.metadata?.name ?? "?";
    const phase = p.status?.phase ?? "?";
    if (phase !== "Running") {
      add({
        severity: "fail",
        code: "PXC_POD_PHASE",
        title: `PXC pod ${n} phase=${phase}`,
        detail: "Database nodes must be Running for the cluster to serve traffic.",
      });
    }
    const cs = p.status?.containerStatuses ?? [];
    for (const c of cs) {
      if (c.ready === false && (c.name === "pxc" || c.name === "database")) {
        add({
          severity: "fail",
          code: "PXC_CONTAINER_NOT_READY",
          title: `Container ${c.name} not ready in ${n}`,
          detail: `restarts=${c.restartCount ?? 0}`,
        });
      }
      const st = c.state as Record<string, { reason?: string; message?: string }> | undefined;
      const waiting = st?.waiting;
      if (waiting?.reason) {
        add({
          severity: "warn",
          code: "PXC_CONTAINER_WAITING",
          title: `${n} / ${c.name} waiting: ${waiting.reason}`,
          detail: waiting.message ?? "",
        });
      }
    }
  }

  for (const p of haPods) {
    const n = p.metadata?.name ?? "?";
    const phase = p.status?.phase ?? "?";
    if (phase !== "Running") {
      add({
        severity: "fail",
        code: "HAPROXY_POD_PHASE",
        title: `HAProxy pod ${n} phase=${phase}`,
        detail: "Unhealthy HAProxy commonly leads to operator 'proxy connection refused'.",
      });
    }
    const cs = p.status?.containerStatuses ?? [];
    for (const c of cs) {
      if (c.ready === false && /haproxy|proxy/i.test(c.name ?? "")) {
        add({
          severity: "fail",
          code: "HAPROXY_CONTAINER_NOT_READY",
          title: `HAProxy-related container not ready: ${n} / ${c.name}`,
          detail: `restarts=${c.restartCount ?? 0}`,
        });
      }
    }
  }

  if (pxcPods.length === 0 && pxcItems.length > 0) {
    add({
      severity: "fail",
      code: "NO_PXC_PODS",
      title: "No pods matching *-pxc-<ordinal> pattern",
      detail: "Expected StatefulSet pods for PXC. Check CR name and operator reconciliation.",
    });
  }

  // Services + endpoints (critical for connection refused)
  let services: Service[] = [];
  let endpoints: Endpoints[] = [];
  try {
    const sl = await kubectlJson<K8sList<Service>>(["get", "svc"], ns);
    services = sl.items ?? [];
    const el = await kubectlJson<K8sList<Endpoints>>(["get", "endpoints"], ns);
    endpoints = el.items ?? [];
  } catch (e: unknown) {
    add({
      severity: "warn",
      code: "SVC_EP_LIST",
      title: "Could not fully list Services/Endpoints",
      detail: e instanceof Error ? e.message : String(e),
    });
  }

  const epByName = new Map(endpoints.map((e) => [e.metadata?.name ?? "", e]));

  for (const svc of services) {
    const sn = svc.metadata?.name ?? "";
    if (!sn || sn === "kubernetes") continue;
    const isDbRelated =
      /haproxy|mysql|pxc|writer|reader|replicas/i.test(sn) ||
      (svc.spec?.ports?.some((p) => p.port === 3306 || p.port === 3307) ?? false);
    if (!isDbRelated) continue;

    const ep = epByName.get(sn);
    const ready = ep?.subsets?.flatMap((s) => s.addresses ?? []) ?? [];
    const notReady = ep?.subsets?.flatMap((s) => s.notReadyAddresses ?? []) ?? [];

    if (ready.length === 0 && notReady.length === 0) {
      add({
        severity: "fail",
        code: "EP_EMPTY",
        title: `Service "${sn}" has no ready or notReady endpoint addresses`,
        detail:
          "Traffic to this Service will fail (connection refused / no route). Check selectors and backend pods.",
      });
    } else if (ready.length === 0 && notReady.length > 0) {
      add({
        severity: "fail",
        code: "EP_ONLY_NOT_READY",
        title: `Service "${sn}" has only notReadyAddresses (${notReady.length})`,
        detail: "Pods may exist but are not passing readiness; proxies cannot use them.",
      });
    }
  }

  // PVCs
  try {
    const pvcs = await kubectlJson<K8sList<PVC>>(["get", "pvc"], ns);
    for (const pvc of pvcs.items ?? []) {
      const ph = pvc.status?.phase;
      if (ph && ph !== "Bound") {
        add({
          severity: "fail",
          code: "PVC_NOT_BOUND",
          title: `PVC ${pvc.metadata?.name} phase=${ph}`,
          detail: "Unbound PVCs block StatefulSet scheduling and startup.",
        });
      }
    }
  } catch {
    /* ignore */
  }

  // Network policies
  try {
    const npl = await kubectlJson<K8sList<NetworkPolicy>>(
      ["get", "networkpolicies.networking.k8s.io"],
      ns
    );
    const nps = npl.items ?? [];
    if (nps.length > 0) {
      add({
        severity: "info",
        code: "NETPOL_PRESENT",
        title: `${nps.length} NetworkPolicy object(s) in namespace`,
        detail: `Names: ${nps.map((n) => n.metadata?.name).join(", ")}. May block operator → pod or pod → pod traffic if mis-scoped.`,
      });
    }
  } catch {
    /* ignore if API disabled */
  }

  // Recent warning events
  try {
    const ev = await kubectlJson<K8sList<Event>>(
      ["get", "events", "--field-selector", "type=Warning"],
      ns
    );
    const items = (ev.items ?? [])
      .filter((e) => /Failed|BackOff|Unhealthy|Error|Denied/i.test(e.reason ?? ""))
      .slice(-12);
    for (const e of items) {
      add({
        severity: "warn",
        code: "EVENT_WARNING",
        title: `Event ${e.reason} on ${e.involvedObject?.kind}/${e.involvedObject?.name}`,
        detail: (e.message ?? "").slice(0, 500),
      });
    }
  } catch {
    /* ignore */
  }

  // Operator pods (often different namespace — optional hint)
  try {
    const ops = await kubectlJson<K8sList<Pod>>(["get", "pods", "-l", "app.kubernetes.io/name=percona-xtradb-cluster-operator", "-A"]);
    const opItems = ops.items ?? [];
    if (opItems.length === 0) {
      add({
        severity: "info",
        code: "OPERATOR_NOT_FOUND_CLUSTER",
        title: "No operator pods found cluster-wide with label app.kubernetes.io/name=percona-xtradb-cluster-operator",
        detail: "Operator may use a different label or may be outside your RBAC view.",
      });
    } else {
      const bad = opItems.filter((p) => p.status?.phase !== "Running");
      if (bad.length > 0) {
        add({
          severity: "warn",
          code: "OPERATOR_POD_BAD",
          title: "Some PXC operator pods are not Running",
          detail: bad.map((p) => `${p.metadata?.namespace}/${p.metadata?.name}:${p.status?.phase}`).join("; "),
        });
      }
    }
  } catch {
    /* RBAC may forbid -A */
  }

  return findings;
}

export async function clusterContextSummary(): Promise<string> {
  try {
    const ctx = await kubectlText(["config", "current-context"]);
    const ver = await kubectlText(["version", "--short"]).catch(() => "");
    return `kubectl context: ${ctx}\n${ver ? ver + "\n" : ""}`;
  } catch (e: unknown) {
    return e instanceof Error ? e.message : String(e);
  }
}

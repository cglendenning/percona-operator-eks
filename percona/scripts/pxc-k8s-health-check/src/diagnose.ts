import type { Finding, Prescription } from "./types";

const k = 'kubectl --kubeconfig="$KUBECONFIG"';

function codesPresent(findings: Finding[], codes: string[]): boolean {
  return findings.some((f) => codes.includes(f.code));
}

function codeFailed(findings: Finding[], code: string): boolean {
  return findings.some((f) => f.code === code && f.severity === "fail");
}

export function buildPrescriptions(ns: string, findings: Finding[]): Prescription[] {
  const rx: Prescription[] = [];

  if (codeFailed(findings, "NS_MISSING")) {
    rx.push({
      title: "Namespace missing or RBAC denied",
      probableRootCause:
        "Wrong namespace name, kubeconfig context, or your user cannot read namespaces.",
      commands: [
        `${k} get ns`,
        `${k} config get-contexts`,
      ],
    });
    return rx;
  }

  if (codeFailed(findings, "PXC_CRD_OR_API")) {
    rx.push({
      title: "Cannot access PerconaXtraDBCluster API",
      probableRootCause:
        "PXC operator CRDs not installed, wrong cluster, or RBAC blocks custom objects.",
      commands: [
        `${k} api-resources | grep -i pxc`,
        `${k} get crd perconaxtradbclusters.pxc.percona.com`,
      ],
    });
  }

  if (codesPresent(findings, ["NO_PXC_CR"])) {
    rx.push({
      title: "No PXC custom resource in namespace",
      probableRootCause:
        "Cluster not deployed in this namespace or CR was deleted.",
      commands: [
        `${k} get perconaxtradbclusters.pxc.percona.com -n ${ns}`,
        `${k} get all -n ${ns}`,
      ],
    });
  }

  if (
    codesPresent(findings, [
      "EP_EMPTY",
      "EP_ONLY_NOT_READY",
      "HAPROXY_NOT_READY",
      "HAPROXY_POD_PHASE",
      "HAPROXY_CONTAINER_NOT_READY",
    ])
  ) {
    rx.push({
      title: "HAProxy / Service endpoints (common for 'proxy connection refused')",
      probableRootCause:
        "The operator often connects to MySQL through the HAProxy Service. If HAProxy pods are not Ready or Endpoints have no ready addresses, the control plane gets connection refused even though resources 'exist'.",
      commands: [
        `${k} get perconaxtradbclusters.pxc.percona.com -n ${ns} -o yaml | head -80`,
        `${k} get pods -n ${ns} -o wide | grep -E 'haproxy|pxc'`,
        `${k} get svc,endpoints -n ${ns} -o wide`,
        `${k} describe endpoints -n ${ns}`,
        `${k} logs -n ${ns} -l 'app.kubernetes.io/component=haproxy' --tail=80 --all-containers=true`,
      ],
      notes: [
        "Compare Service .spec.selector to pod labels; mismatches produce empty Endpoints.",
        "If HAProxy is CrashLooping, logs usually show backend PXC nodes unreachable.",
      ],
    });
  }

  if (
    codesPresent(findings, [
      "PXC_POD_PHASE",
      "PXC_CONTAINER_NOT_READY",
      "PXC_NOT_FULLY_READY",
    ])
  ) {
    rx.push({
      title: "PXC database pods not healthy",
      probableRootCause:
        "PXC nodes not Running/Ready; HAProxy and SST/join logic fail; operator health checks fail.",
      commands: [
        `${k} get pods -n ${ns} -o wide | grep pxc`,
        `${k} get pods -n ${ns} -o name | grep -E 'pxc-[0-9]+' | head -1`,
        `${k} describe pod -n ${ns} PXC_POD_NAME   # replace with name from previous line`,
        `${k} logs -n ${ns} PXC_POD_NAME -c pxc --tail=120`,
      ],
    });
  }

  if (codesPresent(findings, ["PVC_NOT_BOUND"])) {
    rx.push({
      title: "PVCs not Bound",
      probableRootCause:
        "No StorageClass, wrong StorageClass, quota, or provisioner failure; pods cannot start.",
      commands: [
        `${k} get pvc -n ${ns}`,
        `${k} describe pvc -n ${ns}`,
        `${k} get storageclass`,
      ],
    });
  }

  if (codesPresent(findings, ["NETPOL_PRESENT"])) {
    rx.push({
      title: "NetworkPolicy present — verify operator path",
      probableRootCause:
        "Policies may block traffic from the operator Pod to PXC/HAProxy Services or between pods.",
      commands: [
        `${k} get networkpolicy -n ${ns} -o yaml`,
        `${k} get pods -A -l app.kubernetes.io/name=percona-xtradb-cluster-operator -o wide`,
      ],
      notes: [
        "Confirm operator namespace and target namespace policies allow ingress from operator to MySQL port and DNS.",
      ],
    });
  }

  if (
    findings.some(
      (f) => f.code === "PXC_STATUS" && (f.severity === "fail" || f.severity === "warn")
    )
  ) {
    const pxc = findings.find((f) => f.code === "PXC_STATUS");
    const pxcDetail =
      pxc?.detail == null
        ? ""
        : typeof pxc.detail === "string"
          ? pxc.detail
          : JSON.stringify(pxc.detail);
    rx.push({
      title: "PXC CR reports non-ready state",
      probableRootCause:
        pxcDetail.includes("proxy") || pxcDetail.includes("refused")
          ? "Operator cannot open SQL/admin connection via proxy path (often HAProxy Service → backends)."
          : "Reconciliation or cluster startup error; see status.message and operator logs.",
      commands: [
        `${k} get perconaxtradbclusters.pxc.percona.com -n ${ns} -o yaml`,
        `${k} get events -n ${ns} --sort-by=.lastTimestamp | tail -40`,
        `${k} get pods -A -l app.kubernetes.io/name=percona-xtradb-cluster-operator -o wide`,
        `${k} logs -n OPERATOR_NAMESPACE -l app.kubernetes.io/name=percona-xtradb-cluster-operator --tail=100 --all-containers=true   # set OPERATOR_NAMESPACE`,
      ],
    });
  }

  if (rx.length === 0) {
    rx.push({
      title: "No specific automated prescription",
      probableRootCause:
        "Checks did not hit a known failure pattern, or only informational items were reported.",
      commands: [
        `${k} get perconaxtradbclusters.pxc.percona.com -n ${ns} -o yaml`,
        `${k} get pods,svc,endpoints,pvc -n ${ns}`,
        `${k} get events -n ${ns} --sort-by=.lastTimestamp | tail -50`,
      ],
    });
  }

  return rx;
}

export function summaryLine(findings: Finding[]): string {
  const fail = findings.filter((f) => f.severity === "fail").length;
  const warn = findings.filter((f) => f.severity === "warn").length;
  const ok = findings.filter((f) => f.severity === "ok").length;
  if (fail > 0) return `UNHEALTHY: ${fail} failed, ${warn} warnings, ${ok} ok checks`;
  if (warn > 0) return `DEGRADED: 0 failed, ${warn} warnings, ${ok} ok checks`;
  return `HEALTHY: 0 failed, ${warn} warnings, ${ok} ok checks`;
}

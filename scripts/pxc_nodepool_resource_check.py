#!/usr/bin/env python3
"""
Compare Percona XtraDB Cluster workload resources (requests/limits) against the
Kubernetes node pool implied by the PXC StatefulSet's nodeSelector and required
nodeAffinity (AND with nodeSelector; OR across nodeSelectorTerms, AND within each term).

Requires: Python 3.8+, kubectl on PATH, and a working kubeconfig (same as macOS/Linux).

WSL: Run inside your Linux distro (e.g. Ubuntu on WSL2). Install `python3` and `kubectl`
there, or put a Linux `kubectl` on PATH; keep this file with Unix line endings (LF) if
you edit it on Windows.

Examples:
  python3 scripts/pxc_nodepool_resource_check.py --namespace percona
  python3 scripts/pxc_nodepool_resource_check.py --namespace percona --name my-cluster --with-proxysql
  python3 scripts/pxc_nodepool_resource_check.py --namespace percona --node-labels workload=database,pool=pxc
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def kubectl_json(args: List[str]) -> Any:
    cmd = ["kubectl", *args, "-o", "json"]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"kubectl failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}"
        )
    return json.loads(proc.stdout)


def kubectl_json_allow_missing(args: List[str]) -> Optional[Any]:
    try:
        return kubectl_json(args)
    except RuntimeError:
        return None


def parse_cpu_to_millicores(s: str) -> int:
    s = str(s).strip()
    if not s:
        return 0
    if s.endswith("m"):
        return int(float(s[:-1]))
    return int(float(s) * 1000)


def parse_mem_to_bytes(s: str) -> int:
    s = str(s).strip()
    if not s:
        return 0
    for suffix, mult in (
        ("Ki", 1024),
        ("Mi", 1024**2),
        ("Gi", 1024**3),
        ("Ti", 1024**4),
        ("K", 1000),
        ("M", 1000**2),
        ("G", 1000**3),
        ("T", 1000**4),
    ):
        if s.endswith(suffix):
            return int(float(s[: -len(suffix)]) * mult)
    return int(s)


def millicores_str(mc: int) -> str:
    return f"{mc}m ({mc / 1000:.3g} cores)"


def bytes_str(b: int) -> str:
    if b >= 1024**3:
        return f"{b / 1024**3:.2f}Gi"
    if b >= 1024**2:
        return f"{b / 1024**2:.0f}Mi"
    return f"{b}B"


@dataclass
class ResourcePair:
    cpu_mc: int = 0
    mem_b: int = 0


def add_resources(dst: ResourcePair, cpu: Optional[str], mem: Optional[str]) -> None:
    if cpu:
        dst.cpu_mc += parse_cpu_to_millicores(cpu)
    if mem:
        dst.mem_b += parse_mem_to_bytes(mem)


def container_resources_sum(containers: List[Dict[str, Any]]) -> Tuple[ResourcePair, ResourcePair]:
    req = ResourcePair()
    lim = ResourcePair()
    for c in containers or []:
        r = c.get("resources") or {}
        add_resources(req, (r.get("requests") or {}).get("cpu"), (r.get("requests") or {}).get("memory"))
        add_resources(lim, (r.get("limits") or {}).get("cpu"), (r.get("limits") or {}).get("memory"))
    return req, lim


def node_ready(node: Dict[str, Any]) -> bool:
    for c in node.get("status", {}).get("conditions") or []:
        if c.get("type") == "Ready" and c.get("status") == "True":
            return True
    return False


def match_expressions(labels: Dict[str, str], exprs: List[Dict[str, Any]]) -> bool:
    for e in exprs or []:
        key = e.get("key")
        op = e.get("operator")
        values = e.get("values") or []
        lv = labels.get(key)
        if op == "In":
            if lv not in values:
                return False
        elif op == "NotIn":
            if lv in values:
                return False
        elif op == "Exists":
            if lv is None:
                return False
        elif op == "DoesNotExist":
            if lv is not None:
                return False
        elif op == "Gt":
            if lv is None or not str(lv).isdigit() or not values:
                return False
            if int(lv) <= int(values[0]):
                return False
        elif op == "Lt":
            if lv is None or not str(lv).isdigit() or not values:
                return False
            if int(lv) >= int(values[0]):
                return False
        else:
            return False
    return True


def node_matches_selector_term(labels: Dict[str, str], term: Dict[str, Any]) -> bool:
    if term.get("matchFields"):
        # Rare; treat as unsupported -> False
        return False
    return match_expressions(labels, term.get("matchExpressions") or [])


def node_matches_required_node_affinity(labels: Dict[str, str], aff: Optional[Dict[str, Any]]) -> bool:
    if not aff:
        return True
    na = aff.get("nodeAffinity") or {}
    req = na.get("requiredDuringSchedulingIgnoredDuringExecution") or {}
    terms = req.get("nodeSelectorTerms") or []
    if not terms:
        return True
    return any(node_matches_selector_term(labels, t) for t in terms)


def node_matches_node_selector(labels: Dict[str, str], sel: Optional[Dict[str, str]]) -> bool:
    if not sel:
        return True
    for k, v in sel.items():
        if labels.get(k) != v:
            return False
    return True


def node_in_pool(labels: Dict[str, str], node_selector: Dict[str, str], affinity: Optional[Dict[str, Any]]) -> bool:
    return node_matches_node_selector(labels, node_selector or None) and node_matches_required_node_affinity(
        labels, affinity
    )


def manual_pool_labels(arg: Optional[str]) -> Optional[Dict[str, str]]:
    if not arg:
        return None
    out: Dict[str, str] = {}
    for part in arg.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            raise ValueError(f"Invalid --node-labels entry (expected k=v): {part!r}")
        k, v = part.split("=", 1)
        out[k.strip()] = v.strip()
    return out or None


def list_pxc_names(namespace: str) -> List[str]:
    data = kubectl_json(["get", "pxc", "-n", namespace])
    return [i["metadata"]["name"] for i in data.get("items", [])]


def get_sts(namespace: str, name: str) -> Dict[str, Any]:
    return kubectl_json(["get", "sts", name, "-n", namespace])


def find_pool_nodes(
    nodes_data: Dict[str, Any],
    node_selector: Dict[str, str],
    affinity: Optional[Dict[str, Any]],
    manual_labels: Optional[Dict[str, str]],
) -> List[Dict[str, Any]]:
    pool: List[Dict[str, Any]] = []
    for n in nodes_data.get("items", []):
        if not node_ready(n):
            continue
        labels = n.get("metadata", {}).get("labels") or {}
        if manual_labels:
            if not node_matches_node_selector(labels, manual_labels):
                continue
        elif not node_in_pool(labels, node_selector, affinity):
            continue
        pool.append(n)
    return pool


def pods_on_nodes(node_names: set) -> List[Dict[str, Any]]:
    """All pods bound to any of the given nodes (cluster-wide)."""
    data = kubectl_json(["get", "pods", "--all-namespaces"])
    out: List[Dict[str, Any]] = []
    for p in data.get("items", []):
        nn = (p.get("spec") or {}).get("nodeName")
        if nn and nn in node_names:
            out.append(p)
    return out


def pod_scheduled_resources(pod: Dict[str, Any]) -> ResourcePair:
    """Approximate schedulable requests: sum(containers) + max(initContainers) per k8s rules (simplified)."""
    spec = pod.get("spec") or {}
    c_req, _ = container_resources_sum(spec.get("containers") or [])
    max_init = ResourcePair()
    for ic in spec.get("initContainers") or []:
        r = ic.get("resources") or {}
        ir = ResourcePair()
        add_resources(ir, (r.get("requests") or {}).get("cpu"), (r.get("requests") or {}).get("memory"))
        if ir.cpu_mc > max_init.cpu_mc:
            max_init.cpu_mc = ir.cpu_mc
        if ir.mem_b > max_init.mem_b:
            max_init.mem_b = ir.mem_b
    total = ResourcePair(cpu_mc=c_req.cpu_mc + max_init.cpu_mc, mem_b=c_req.mem_b + max_init.mem_b)
    return total


def sts_total_scheduled(sts: Dict[str, Any]) -> Tuple[int, ResourcePair, ResourcePair]:
    tpl = (sts.get("spec") or {}).get("template") or {}
    spec = tpl.get("spec") or {}
    reps = int((sts.get("spec") or {}).get("replicas") or 0)
    c_req, c_lim = container_resources_sum(spec.get("containers") or [])
    return reps, ResourcePair(cpu_mc=c_req.cpu_mc * reps, mem_b=c_req.mem_b * reps), ResourcePair(
        cpu_mc=c_lim.cpu_mc * reps, mem_b=c_lim.mem_b * reps
    )


def main() -> int:
    if not shutil.which("kubectl"):
        eprint("kubectl not found on PATH. Install kubectl in this environment (including WSL), then retry.")
        return 127

    ap = argparse.ArgumentParser(description="PXC workload vs node-pool allocatable (nodeSelector + required nodeAffinity)")
    ap.add_argument("--namespace", "-n", required=True, help="Namespace of the PerconaXtraDBCluster")
    ap.add_argument("--name", help="PerconaXtraDBCluster metadata.name (default: sole PXC in namespace)")
    ap.add_argument("--with-proxysql", action="store_true", help="Also include the <name>-proxysql StatefulSet")
    ap.add_argument(
        "--node-labels",
        help="Override pool: comma-separated k=v; only nodes matching ALL pairs (ignores STS nodeSelector/affinity)",
    )
    ap.add_argument("--strict", action="store_true", help="Exit 1 if any warning condition triggers")
    args = ap.parse_args()

    try:
        manual = manual_pool_labels(args.node_labels)
    except ValueError as ex:
        eprint(ex)
        return 2

    names = list_pxc_names(args.namespace)
    if not names:
        eprint(f"No PerconaXtraDBCluster (pxc) found in namespace {args.namespace!r}")
        return 1
    if args.name:
        cr_name = args.name
        if cr_name not in names:
            eprint(f"PXC {cr_name!r} not found in namespace {args.namespace!r}. Found: {', '.join(names)}")
            return 1
    elif len(names) != 1:
        eprint(f"Multiple PXC resources in {args.namespace!r}: {', '.join(names)} — pass --name")
        return 1
    else:
        cr_name = names[0]

    pxc_sts_name = f"{cr_name}-pxc"
    sts = kubectl_json_allow_missing(["get", "sts", pxc_sts_name, "-n", args.namespace])
    if not sts:
        eprint(f"StatefulSet {pxc_sts_name!r} not found in namespace {args.namespace!r}")
        return 1

    tpl = (sts.get("spec") or {}).get("template") or {}
    pod_spec = tpl.get("spec") or {}
    node_selector: Dict[str, str] = dict(pod_spec.get("nodeSelector") or {})
    affinity = pod_spec.get("affinity")

    nodes_data = kubectl_json(["get", "nodes"])
    na = ((affinity or {}).get("nodeAffinity") or {})
    req_na = na.get("requiredDuringSchedulingIgnoredDuringExecution") or {}
    has_hard_node_constraints = bool(node_selector) or bool(req_na.get("nodeSelectorTerms"))

    if manual:
        pool_nodes = find_pool_nodes(nodes_data, node_selector, affinity, manual)
    elif has_hard_node_constraints:
        pool_nodes = find_pool_nodes(nodes_data, node_selector, affinity, None)
    else:
        pool_nodes = []

    if not pool_nodes and not manual:
        # No explicit pool: derive from nodes where PXC pods are running (matches default template with only anti-affinity).
        pods_data = kubectl_json(["get", "pods", "-n", args.namespace, "-l", "app.kubernetes.io/component=pxc"])
        nn = {
            (p.get("spec") or {}).get("nodeName")
            for p in pods_data.get("items", [])
            if (p.get("spec") or {}).get("nodeName")
        }
        nn.discard(None)
        pool_nodes = [n for n in nodes_data.get("items", []) if node_ready(n) and n["metadata"]["name"] in nn]
        if pool_nodes:
            eprint(
                "[warn] PXC StatefulSet has no nodeSelector / required nodeAffinity; "
                "using nodes where PXC pods are currently scheduled as the pool. "
                "Add a nodeSelector (or pass --node-labels) to evaluate a dedicated node class explicitly."
            )

    if not pool_nodes:
        eprint(
            "[error] Empty node pool: no Ready nodes match selectors. "
            "Check nodeSelector/affinity on the PXC StatefulSet or use --node-labels k=v,..."
        )
        return 1

    node_names = {n["metadata"]["name"] for n in pool_nodes}
    alloc = ResourcePair()
    per_node_alloc: List[Tuple[str, ResourcePair]] = []
    for n in pool_nodes:
        a = n.get("status", {}).get("allocatable") or {}
        cpu = a.get("cpu", "0")
        mem = a.get("memory", "0")
        pair = ResourcePair(parse_cpu_to_millicores(cpu), parse_mem_to_bytes(mem))
        per_node_alloc.append((n["metadata"]["name"], pair))
        alloc.cpu_mc += pair.cpu_mc
        alloc.mem_b += pair.mem_b

    all_pods = pods_on_nodes(node_names)
    used_on_pool = ResourcePair()
    per_node_used: Dict[str, ResourcePair] = {name: ResourcePair() for name in node_names}
    for p in all_pods:
        phase = (p.get("status") or {}).get("phase")
        if phase in ("Succeeded", "Failed"):
            continue
        nn = (p.get("spec") or {}).get("nodeName")
        if not nn:
            continue
        pr = pod_scheduled_resources(p)
        used_on_pool.cpu_mc += pr.cpu_mc
        used_on_pool.mem_b += pr.mem_b
        per_node_used[nn].cpu_mc += pr.cpu_mc
        per_node_used[nn].mem_b += pr.mem_b

    workloads: List[Tuple[str, Dict[str, Any]]] = [(pxc_sts_name, sts)]
    if args.with_proxysql:
        psql = kubectl_json_allow_missing(["get", "sts", f"{cr_name}-proxysql", "-n", args.namespace])
        if psql:
            workloads.append((f"{cr_name}-proxysql", psql))
        else:
            eprint("[warn] --with-proxysql set but proxysql StatefulSet not found")

    pxc_total = ResourcePair()
    lim_total = ResourcePair()
    for wname, wsts in workloads:
        reps, treq, tlim = sts_total_scheduled(wsts)
        pxc_total.cpu_mc += treq.cpu_mc
        pxc_total.mem_b += treq.mem_b
        lim_total.cpu_mc += tlim.cpu_mc
        lim_total.mem_b += tlim.mem_b
        w_tpl = (wsts.get("spec") or {}).get("template") or {}
        w_spec = w_tpl.get("spec") or {}
        c_req, c_lim = container_resources_sum(w_spec.get("containers") or [])
        eprint(f"[workload] {wname}: replicas={reps} per-pod requests CPU={millicores_str(c_req.cpu_mc)} mem={bytes_str(c_req.mem_b)}")
        eprint(
            f"            per-pod limits   CPU={millicores_str(c_lim.cpu_mc)} mem={bytes_str(c_lim.mem_b)} "
            f"(limit<request is invalid below)"
        )

    print(f"PXC CR: {cr_name}  namespace: {args.namespace}")
    if manual:
        print(f"Node pool: manual labels {manual!r}  ({len(pool_nodes)} ready nodes)")
    else:
        na = ((affinity or {}).get("nodeAffinity") or {})
        req_na = na.get("requiredDuringSchedulingIgnoredDuringExecution") or {}
        n_terms = len(req_na.get("nodeSelectorTerms") or [])
        print(f"Node pool: nodeSelector={node_selector!r}  required nodeAffinity terms={n_terms}")
        print(f"           ({len(pool_nodes)} ready nodes: {', '.join(sorted(node_names))})")
    print(f"Pool allocatable (sum): CPU {millicores_str(alloc.cpu_mc)}  mem {bytes_str(alloc.mem_b)}")
    print(
        f"Pool requested (all pods on these nodes): CPU {millicores_str(used_on_pool.cpu_mc)}  mem {bytes_str(used_on_pool.mem_b)}"
    )
    print(
        f"PXC workload scheduled totals: CPU {millicores_str(pxc_total.cpu_mc)}  mem {bytes_str(pxc_total.mem_b)} "
        f"(limits aggregate CPU {millicores_str(lim_total.cpu_mc)} mem {bytes_str(lim_total.mem_b)})"
    )

    warnings: List[str] = []

    if pxc_total.cpu_mc > alloc.cpu_mc or pxc_total.mem_b > alloc.mem_b:
        warnings.append(
            "PXC aggregate requests exceed pool allocatable (cluster cannot satisfy requests even if empty)."
        )
    if lim_total.cpu_mc > alloc.cpu_mc or lim_total.mem_b > alloc.mem_b:
        warnings.append(
            "PXC aggregate limits exceed pool allocatable (simultaneous burst cannot be satisfied on this pool)."
        )

    max_node_cpu = max(p.cpu_mc for _, p in per_node_alloc)
    max_node_mem = max(p.mem_b for _, p in per_node_alloc)
    tpl_spec = ((sts.get("spec") or {}).get("template") or {}).get("spec") or {}
    one_pod_req, _ = container_resources_sum(tpl_spec.get("containers") or [])
    if one_pod_req.cpu_mc > max_node_cpu or one_pod_req.mem_b > max_node_mem:
        warnings.append(
            "Single PXC pod requests exceed the largest allocatable node in the pool (cannot schedule a member)."
        )

    for wname, wsts in workloads:
        w_tpl = (wsts.get("spec") or {}).get("template") or {}
        w_spec = w_tpl.get("spec") or {}
        for c in w_spec.get("containers") or []:
            r = c.get("resources") or {}
            rq = r.get("requests") or {}
            lm = r.get("limits") or {}
            crc, crm = rq.get("cpu"), rq.get("memory")
            clc, clm = lm.get("cpu"), lm.get("memory")
            if crc and clc:
                if parse_cpu_to_millicores(clc) < parse_cpu_to_millicores(crc):
                    warnings.append(f"{wname} container {c.get('name')}: CPU limit < request")
            if crm and clm:
                if parse_mem_to_bytes(clm) < parse_mem_to_bytes(crm):
                    warnings.append(f"{wname} container {c.get('name')}: memory limit < request")

    for nodename, apair in per_node_alloc:
        used = per_node_used.get(nodename, ResourcePair())
        if used.cpu_mc > apair.cpu_mc or used.mem_b > apair.mem_b:
            warnings.append(
                f"Node {nodename} is overcommitted on requests "
                f"(CPU {millicores_str(used.cpu_mc)} > {millicores_str(apair.cpu_mc)} "
                f"or mem {bytes_str(used.mem_b)} > {bytes_str(apair.mem_b)})."
            )

    slack_cpu = alloc.cpu_mc - used_on_pool.cpu_mc
    slack_mem = alloc.mem_b - used_on_pool.mem_b
    print(
        f"Remaining pool capacity (alloc minus requests of all pods on pool): "
        f"CPU {millicores_str(slack_cpu)}  mem {bytes_str(slack_mem)}"
    )
    if slack_cpu < 0 or slack_mem < 0:
        warnings.append(
            "Aggregate requests on pool nodes exceed summed allocatable (pool is overcommitted on requests)."
        )

    if warnings:
        print("\nWarnings:")
        for w in warnings:
            print(f"  - {w}")
        return 1 if args.strict else 0

    print("\nNo warning conditions detected (see --strict to fail CI on warnings).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

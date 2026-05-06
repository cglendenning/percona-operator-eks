#!/usr/bin/env python3
"""
Interactive MySQL error log triage via kubectl exec.

Contract:
  - Requires: kubectl on PATH, KUBECONFIG set to a single kubeconfig file path.
  - Always uses: kubectl --kubeconfig "$KUBECONFIG" ...
  - Works on: macOS and WSL (Python 3.9+ recommended).

This script contains a static analyzer that correlates multiple error signals to
produce a single recommended resolution path.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


MYSQL_ERROR_LOG_PATH = "/var/lib/mysql/mysqld-error.log"


class UserFacingError(Exception):
    pass


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def require_env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise UserFacingError(f"{name} is not set. Export {name}=/path/to/kubeconfig")
    return v


def kubectl_base_args() -> List[str]:
    kubeconfig = require_env("KUBECONFIG")
    if ":" in kubeconfig:
        # Requirement: always pass --kubeconfig=$KUBECONFIG, which can't represent a merged list.
        raise UserFacingError(
            "KUBECONFIG contains ':' (multiple kubeconfigs). This script requires KUBECONFIG "
            "to be a single file path so it can pass --kubeconfig \"$KUBECONFIG\"."
        )
    return ["kubectl", "--kubeconfig", kubeconfig]


def run_checked(args: Sequence[str], timeout_s: int = 30) -> str:
    try:
        cp = subprocess.run(
            list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    except FileNotFoundError as e:
        raise UserFacingError(f"Missing required command: {args[0]}") from e
    except OSError as e:
        # Common on WSL when PATH points at a Windows kubectl.exe or wrong-arch binary.
        if getattr(e, "errno", None) == 8:
            raise UserFacingError(
                "OSError: Exec format error running kubectl.\n"
                "This usually means your 'kubectl' on PATH is not a Linux executable (often a Windows kubectl.exe).\n"
                "Fix: install a Linux kubectl inside WSL and ensure it comes first on PATH.\n"
                "Quick checks:\n"
                "  - which kubectl\n"
                "  - ls -l $(which kubectl)\n"
                "  - file $(which kubectl)\n"
                "If it points under /mnt/c/ or ends with .exe, install kubectl via your WSL distro package manager "
                "or download the Linux binary, then retry."
            ) from e
        raise
    except subprocess.TimeoutExpired as e:
        raise UserFacingError(f"Timed out after {timeout_s}s running: {shlex.join(args)}") from e

    if cp.returncode != 0:
        stderr = (cp.stderr or "").strip()
        stdout = (cp.stdout or "").strip()
        detail = stderr or stdout or f"exit code {cp.returncode}"
        raise UserFacingError(f"Command failed: {shlex.join(args)}\n{detail}")
    return (cp.stdout or "").strip("\n")


def run_maybe(args: Sequence[str], timeout_s: int = 30) -> Tuple[int, str, str]:
    try:
        cp = subprocess.run(
            list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    except FileNotFoundError:
        return 127, "", f"Missing required command: {args[0]}"
    except OSError as e:
        if getattr(e, "errno", None) == 8:
            return (
                126,
                "",
                (
                    "OSError: Exec format error running kubectl. "
                    "Your 'kubectl' on PATH is not a Linux executable (often Windows kubectl.exe). "
                    "Install a Linux kubectl in WSL and ensure it is first on PATH."
                ),
            )
        return 126, "", str(e)
    except subprocess.TimeoutExpired:
        return 124, "", f"Timed out after {timeout_s}s running: {shlex.join(args)}"
    return cp.returncode, (cp.stdout or ""), (cp.stderr or "")


def choose_from_menu(title: str, options: List[str], allow_quit: bool = True) -> str:
    if not options:
        raise UserFacingError(f"No options available for: {title}")

    print("")
    print(title)
    print("-" * len(title))
    for i, opt in enumerate(options, start=1):
        print(f"{i:>3}) {opt}")
    if allow_quit:
        print("  q) quit")

    while True:
        raw = input("> ").strip()
        if allow_quit and raw.lower() in {"q", "quit", "exit"}:
            raise UserFacingError("User quit.")
        if raw.isdigit():
            idx = int(raw)
            if 1 <= idx <= len(options):
                return options[idx - 1]
        print(f"Enter 1-{len(options)}" + (" or q" if allow_quit else ""))


def unique_sorted(xs: Iterable[str]) -> List[str]:
    return sorted({x for x in xs if x})


def list_namespaces() -> List[str]:
    base = kubectl_base_args()
    # Prefer namespaces directly; RBAC may block it.
    rc, out, err = run_maybe(base + ["get", "namespaces", "-o", "json"], timeout_s=30)
    if rc == 0:
        try:
            j = json.loads(out)
            return unique_sorted([i.get("metadata", {}).get("name", "") for i in j.get("items", [])])
        except json.JSONDecodeError:
            pass

    # Fallback: derive namespaces from pods across all namespaces (often allowed).
    rc2, out2, err2 = run_maybe(base + ["get", "pods", "-A", "-o", "json"], timeout_s=30)
    if rc2 == 0:
        try:
            j2 = json.loads(out2)
            return unique_sorted([i.get("metadata", {}).get("namespace", "") for i in j2.get("items", [])])
        except json.JSONDecodeError:
            pass

    # If both failed, surface most informative error.
    detail = (err or "").strip() or (err2 or "").strip() or "Unable to list namespaces or pods (RBAC?)."
    raise UserFacingError(detail)


@dataclass(frozen=True)
class PodChoice:
    name: str
    phase: str
    ready: str
    restarts: int


def list_pods(namespace: str) -> List[PodChoice]:
    base = kubectl_base_args()
    out = run_checked(base + ["get", "pods", "-n", namespace, "-o", "json"], timeout_s=30)
    j = json.loads(out)

    pods: List[PodChoice] = []
    for item in j.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        phase = item.get("status", {}).get("phase", "")
        statuses = item.get("status", {}).get("containerStatuses") or []
        ready_count = sum(1 for s in statuses if s.get("ready") is True)
        total = len(statuses) if statuses else 0
        ready = f"{ready_count}/{total}" if total else "0/0"
        restarts = sum(int(s.get("restartCount") or 0) for s in statuses)
        if name:
            pods.append(PodChoice(name=name, phase=phase, ready=ready, restarts=restarts))

    # Sort: Running first, then by restarts desc, then name.
    def key(p: PodChoice) -> Tuple[int, int, str]:
        running_rank = 0 if p.phase == "Running" else 1
        return (running_rank, -p.restarts, p.name)

    return sorted(pods, key=key)


def describe_pod_line(p: PodChoice) -> str:
    bits = [p.name]
    if p.phase:
        bits.append(f"phase={p.phase}")
    if p.ready:
        bits.append(f"ready={p.ready}")
    bits.append(f"restarts={p.restarts}")
    return "  ".join(bits)


def get_pod_containers(namespace: str, pod: str) -> List[str]:
    base = kubectl_base_args()
    out = run_checked(base + ["get", "pod", pod, "-n", namespace, "-o", "json"], timeout_s=30)
    j = json.loads(out)
    cs = j.get("spec", {}).get("containers") or []
    return [c.get("name", "") for c in cs if c.get("name")]


def kubectl_exec_cat(namespace: str, pod: str, container: Optional[str], path: str) -> str:
    base = kubectl_base_args()
    args = base + ["exec", "-n", namespace]
    if container:
        args += ["-c", container]
    args += [pod, "--", "sh", "-lc", f"test -r {shlex.quote(path)} && cat {shlex.quote(path)}"]
    out = run_checked(args, timeout_s=30)
    return out


def looks_like_multi_container_error(stderr: str) -> bool:
    # kubectl error messages vary slightly by version.
    s = stderr.lower()
    return ("container" in s and "must be specified" in s) or ("choose one of" in s and "container" in s)


def fetch_mysql_error_log(namespace: str, pod: str) -> Tuple[str, Optional[str]]:
    # Try without container first; if needed, prompt and retry.
    base = kubectl_base_args()
    args = base + [
        "exec",
        "-n",
        namespace,
        pod,
        "--",
        "sh",
        "-lc",
        f"test -r {shlex.quote(MYSQL_ERROR_LOG_PATH)} && cat {shlex.quote(MYSQL_ERROR_LOG_PATH)}",
    ]
    rc, out, err = run_maybe(args, timeout_s=30)
    if rc == 0:
        return out.strip("\n"), None

    if looks_like_multi_container_error(err):
        containers = get_pod_containers(namespace, pod)
        if not containers:
            raise UserFacingError(f"Pod {pod} has no containers?")
        chosen = choose_from_menu("Choose container", containers, allow_quit=True)
        log = kubectl_exec_cat(namespace, pod, chosen, MYSQL_ERROR_LOG_PATH)
        return log.strip("\n"), chosen

    detail = (err or "").strip() or (out or "").strip() or f"kubectl exec failed (exit {rc})"
    raise UserFacingError(detail)


@dataclass
class Finding:
    key: str
    severity: str  # "critical" | "warn" | "info"
    evidence: List[str]


def _grep_lines(text: str, patterns: Sequence[re.Pattern], max_evidence: int = 6) -> List[str]:
    ev: List[str] = []
    for line in text.splitlines():
        for p in patterns:
            if p.search(line):
                ev.append(line.strip())
                if len(ev) >= max_evidence:
                    return ev
                break
    return ev


def analyze_mysql_error_log(text: str) -> Tuple[List[Finding], List[str]]:
    """
    Returns (findings, recommendations).

    Recommendations are combination-aware: we treat some signals as root causes
    (disk full, permissions, corruption) that explain other secondary errors.
    """

    findings: List[Finding] = []
    recs: List[str] = []

    # Canonical signals (static patterns).
    sig_disk_full = _grep_lines(
        text,
        [
            re.compile(r"Operating system error number 28", re.I),
            re.compile(r"No space left on device", re.I),
            re.compile(r"Disk is full", re.I),
            re.compile(r"errno: 28", re.I),
        ],
    )
    sig_perm = _grep_lines(
        text,
        [
            re.compile(r"Operating system error number 13", re.I),
            re.compile(r"Permission denied", re.I),
            re.compile(r"errno: 13", re.I),
        ],
    )
    sig_ro_fs = _grep_lines(text, [re.compile(r"Read-only file system", re.I)])
    sig_io = _grep_lines(
        text,
        [
            re.compile(r"Input/output error", re.I),
            re.compile(r"Operating system error number 5", re.I),
            re.compile(r"errno: 5", re.I),
        ],
    )
    sig_oom = _grep_lines(
        text,
        [
            re.compile(r"Out of memory", re.I),
            re.compile(r"Cannot allocate memory", re.I),
            re.compile(r"std::bad_alloc", re.I),
        ],
    )
    sig_innodb_corruption = _grep_lines(
        text,
        [
            re.compile(r"InnoDB:.*corrupt", re.I),
            re.compile(r"InnoDB:.*page.*corrupt", re.I),
            re.compile(r"InnoDB:.*checksum.*mismatch", re.I),
            re.compile(r"InnoDB:.*crash recovery", re.I),
            re.compile(r"InnoDB:.*log sequence number", re.I),
            re.compile(r"InnoDB: Unable to open .*ibdata", re.I),
        ],
        max_evidence=10,
    )
    sig_redo = _grep_lines(
        text,
        [
            re.compile(r"InnoDB:.*redo", re.I),
            re.compile(r"InnoDB:.*log file.*(mismatch|is of different size)", re.I),
            re.compile(r"ib_logfile", re.I),
            re.compile(r"#innodb_redo", re.I),
        ],
    )
    sig_wsrep = _grep_lines(
        text,
        [
            re.compile(r"WSREP:", re.I),
            re.compile(r"wsrep", re.I),
            re.compile(r"galera", re.I),
            re.compile(r"sst", re.I),
            re.compile(r"ist", re.I),
        ],
        max_evidence=10,
    )
    sig_network = _grep_lines(
        text,
        [
            re.compile(r"Connection timed out", re.I),
            re.compile(r"Broken pipe", re.I),
            re.compile(r"Connection refused", re.I),
            re.compile(r"Host is unreachable", re.I),
        ],
    )
    sig_tls = _grep_lines(
        text,
        [
            re.compile(r"SSL", re.I),
            re.compile(r"TLS", re.I),
            re.compile(r"x509", re.I),
            re.compile(r"certificate", re.I),
            re.compile(r"unknown ca", re.I),
        ],
        max_evidence=10,
    )

    # Record findings.
    if sig_disk_full:
        findings.append(Finding("disk_full", "critical", sig_disk_full))
    if sig_ro_fs:
        findings.append(Finding("read_only_filesystem", "critical", sig_ro_fs))
    if sig_perm:
        findings.append(Finding("permission_denied", "critical", sig_perm))
    if sig_io:
        findings.append(Finding("io_error", "critical", sig_io))
    if sig_oom:
        findings.append(Finding("oom", "critical", sig_oom))
    if sig_innodb_corruption:
        # Treat corruption/crash-recovery as critical when accompanied by IO/disk/redo issues,
        # otherwise warn (crash recovery alone can be normal).
        sev = "critical" if (sig_io or sig_disk_full or sig_redo) else "warn"
        findings.append(Finding("innodb_corruption_or_recovery", sev, sig_innodb_corruption))
    if sig_redo:
        findings.append(Finding("innodb_redo_log_issue", "critical", sig_redo))
    if sig_wsrep:
        findings.append(Finding("wsrep_galera", "warn", sig_wsrep))
    if sig_network:
        findings.append(Finding("network_errors", "warn", sig_network))
    if sig_tls:
        findings.append(Finding("tls_ssl", "warn", sig_tls))

    keys = {f.key for f in findings}

    # Combination-aware recommendation path selection.
    #
    # Rule ordering is intentional: root causes first, then secondary/cluster behaviors.
    if "disk_full" in keys or "read_only_filesystem" in keys:
        recs.append(
            "Primary issue is storage. Free space or expand the PVC/volume, then restart the pod. "
            "If the filesystem is read-only, check node/kernel/dmesg for disk errors and reattach or replace the volume."
        )
        if "innodb_corruption_or_recovery" in keys:
            recs.append(
                "Disk-full / read-only events can corrupt InnoDB. After restoring storage health, prefer recovery by "
                "recreating the pod from a healthy replica (Galera) or restoring from a backup, rather than forcing InnoDB recovery."
            )
        return findings, recs

    if "permission_denied" in keys:
        recs.append(
            "Primary issue is permissions. Verify the MySQL container runs as the expected UID/GID and that the "
            "PVC mount ownership/permissions allow writes under /var/lib/mysql. In Kubernetes this is typically fixed "
            "by setting fsGroup/runAsUser correctly or correcting the volume's ownership."
        )
        if "wsrep_galera" in keys:
            recs.append(
                "If this is a Percona XtraDB Cluster pod, permissions issues commonly block SST/IST and state transfers. "
                "Fix permissions first, then restart the failing pod so it can re-join."
            )
        return findings, recs

    if "io_error" in keys:
        recs.append(
            "Primary issue is I/O errors. Treat this as underlying storage instability: check node and volume health "
            "(cloud volume metrics / CSI events), and consider moving/recreating the pod on healthy storage. Avoid repeated restarts; "
            "they can worsen corruption."
        )
        if "innodb_corruption_or_recovery" in keys or "innodb_redo_log_issue" in keys:
            recs.append(
                "I/O errors plus InnoDB errors strongly suggests data-file/redo corruption. Prefer recovery by restoring from backup "
                "or re-seeding from a healthy cluster member. Only use InnoDB force recovery as a last resort to extract data."
            )
        return findings, recs

    if "oom" in keys:
        recs.append(
            "Primary issue is memory pressure. Increase container memory limit/requests and/or tune MySQL memory usage "
            "(e.g., lower innodb_buffer_pool_size) so mysqld can start and complete crash recovery."
        )
        if "innodb_corruption_or_recovery" in keys:
            recs.append(
                "If crash recovery is present, OOM can prevent it from completing; fix memory first before attempting other changes."
            )
        return findings, recs

    if "innodb_redo_log_issue" in keys:
        recs.append(
            "Detected InnoDB redo log mismatch/corruption signals. In operator-managed clusters, the safest resolution is usually "
            "to re-seed the affected pod from a healthy replica (delete the pod and let it rejoin with SST/IST) or restore from backup. "
            "Avoid manual deletion of redo files unless you are explicitly performing a documented recovery procedure."
        )
        return findings, recs

    if "innodb_corruption_or_recovery" in keys:
        # Distinguish normal recovery vs repeated corruption.
        if any("corrupt" in " ".join(f.evidence).lower() for f in findings if f.key == "innodb_corruption_or_recovery"):
            recs.append(
                "Detected explicit InnoDB corruption signals. Prefer recovery via restore from backup or re-seeding from a healthy node. "
                "If you must salvage data, use InnoDB force recovery only temporarily and only for logical dump/export."
            )
        else:
            recs.append(
                "InnoDB crash recovery messages are present. If mysqld is not coming up, inspect preceding errors for the first failure; "
                "common blockers are disk space, permissions, OOM, or I/O."
            )
        # Continue to check wsrep below.

    if "wsrep_galera" in keys:
        # Correlate with network/tls.
        if "tls_ssl" in keys and "network_errors" in keys:
            recs.append(
                "WSREP/Galera issues plus TLS/network errors suggests connectivity/cert mismatch between cluster members. "
                "Verify service DNS, network policies, and that all members agree on TLS settings/certs for replication."
            )
        elif "network_errors" in keys:
            recs.append(
                "WSREP/Galera issues plus network errors suggests the pod cannot reach peers reliably. "
                "Verify network policy, CNI health, and that peer Services/Endpoints are present."
            )
        else:
            recs.append(
                "WSREP/Galera messages present. If a single pod is failing, the usual safe fix is to re-seed it from a healthy member "
                "(delete the pod so it rejoins). If the whole cluster is down, you may need a bootstrap/recovery procedure."
            )

    if not findings:
        recs.append(
            "No known critical patterns matched in the error log. If mysqld is failing, look for the FIRST error chronologically "
            "near startup and correlate with Kubernetes events (OOMKilled, volume mount issues, node pressure)."
        )

    return findings, recs


def format_findings(findings: List[Finding]) -> str:
    if not findings:
        return "No findings (no patterns matched)."
    order = {"critical": 0, "warn": 1, "info": 2}
    lines: List[str] = []
    for f in sorted(findings, key=lambda x: (order.get(x.severity, 9), x.key)):
        lines.append(f"- {f.severity.upper()}: {f.key}")
        for ev in f.evidence:
            lines.append(f"    {ev}")
    return "\n".join(lines)


def main() -> int:
    try:
        require_env("KUBECONFIG")
        # Quick kubectl probe.
        _ = run_checked(kubectl_base_args() + ["version", "--client=true"], timeout_s=15)

        namespaces = list_namespaces()
        ns = choose_from_menu("Choose namespace", namespaces, allow_quit=True)

        pods = list_pods(ns)
        pod_menu = [describe_pod_line(p) for p in pods]
        selected_line = choose_from_menu("Choose pod", pod_menu, allow_quit=True)
        # Extract pod name (first token).
        pod = selected_line.split()[0]

        log_text, container = fetch_mysql_error_log(ns, pod)
        if not log_text.strip():
            raise UserFacingError(
                f"Log file appears empty or unreadable at {MYSQL_ERROR_LOG_PATH}. "
                "Verify the path inside the container and that the pod is Running."
            )

        findings, recs = analyze_mysql_error_log(log_text)

        print("")
        print("== Context ==")
        print(f"namespace: {ns}")
        print(f"pod: {pod}")
        if container:
            print(f"container: {container}")
        print(f"log: {MYSQL_ERROR_LOG_PATH}")

        print("")
        print("== Findings (evidence excerpts) ==")
        print(format_findings(findings))

        print("")
        print("== Recommendation ==")
        for i, r in enumerate(recs, start=1):
            print(f"{i}. {r}")

        print("")
        print("== Next commands (optional) ==")
        base = shlex.join(kubectl_base_args())
        print(f"- Describe pod: {base} describe pod -n {shlex.quote(ns)} {shlex.quote(pod)}")
        print(f"- Pod events:   {base} get events -n {shlex.quote(ns)} --sort-by=.lastTimestamp | tail -n 50")
        print(f"- Pod logs:     {base} logs -n {shlex.quote(ns)} {shlex.quote(pod)} --tail=200")

        return 0
    except UserFacingError as e:
        msg = str(e).strip()
        if msg and msg != "User quit.":
            eprint(f"error: {msg}")
        return 2
    except KeyboardInterrupt:
        eprint("interrupted")
        return 130
    except json.JSONDecodeError as e:
        eprint(f"error: unexpected JSON parse failure: {e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())


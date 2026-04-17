#!/usr/bin/env bash
# SeaweedFS filer + cluster storage health check for Kubernetes (works on WSL).
#
# The filer stores metadata; blob capacity is on volume servers. This script:
#   - Checks filer pod readiness and HTTP /healthz + /status
#   - Checks master /cluster/healthz and writable volume slot headroom (/dir/status)
#   - Runs df on volume (and optionally filer) pods to catch disks nearing full
#
# Usage:
#   ./seaweedfs-k8s-filer-health.sh [--kubeconfig PATH | --kubeconfig=PATH] [--namespace NS]
#
# Environment (optional):
#   KUBECONFIG          If set to a single file path, kubectl is run with --kubeconfig (same as
#                       `kubectl --kubeconfig=...`). If it contains ':' (multiple files), the
#                       script uses plain kubectl so the merge behavior matches the kubectl CLI.
#   SEAWEED_NAMESPACE   Kubernetes namespace (default: seaweedfs)
#   SEAWEED_FILER_SVC   Master service hostname as seen from pods (default: auto)
#   SEAWEED_MASTER_SVC  Same (default: auto)
#   FILER_CONTAINER     kubectl -c name when the filer pod is multi-container
#   WARN_PCT            df used%% warning threshold (default: 85)
#   CRIT_PCT            df used%% critical threshold (default: 95)
#   MIN_FREE_SLOTS      warn if master's Topology.Free writable slots <= this (default: 2)
#
# Exit codes: 0 healthy, 1 warning, 2 critical (also non-zero for kubectl/runtime errors)

set -euo pipefail

NS="${SEAWEED_NAMESPACE:-seaweedfs}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
WARN_PCT="${WARN_PCT:-85}"
CRIT_PCT="${CRIT_PCT:-95}"
MIN_FREE_SLOTS="${MIN_FREE_SLOTS:-2}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"

MAX_EXIT=0
bump_exit() {
  local level="$1"
  if (( level > MAX_EXIT )); then
    MAX_EXIT=$level
  fi
}

usage() {
  sed -n '1,30p' "$0" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n)
      NS="$2"
      shift 2
      ;;
    --kubeconfig)
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    --kubeconfig=*)
      KUBECONFIG_PATH="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' not found in PATH" >&2
    exit 3
  }
}

need_cmd kubectl

# Match `kubectl --kubeconfig=/path`: use explicit --kubeconfig from the flag, else a single-file
# KUBECONFIG env. If KUBECONFIG lists multiple files (':'), rely on the environment (kubectl merge).
KUBECTL=(kubectl)
if [[ -n "$KUBECONFIG_PATH" ]]; then
  KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
elif [[ -n "${KUBECONFIG:-}" ]]; then
  case "$KUBECONFIG" in
    *:*)
      KUBECTL=(kubectl)
      ;;
    *)
      KUBECTL=(kubectl --kubeconfig "$KUBECONFIG")
      ;;
  esac
fi

# Prefer cluster-scoped `get namespace`; if that fails (RBAC often forbids it), fall back to
# any namespaced read — many roles can list pods but cannot `get namespace`.
if ! "${KUBECTL[@]}" get namespace "$NS" -o name &>/dev/null; then
  if "${KUBECTL[@]}" get pods -n "$NS" --request-timeout=20s &>/dev/null; then
    echo "note: cannot read Namespace object (RBAC); using namespaced API access only." >&2
  else
    echo "error: cannot use namespace '$NS'. Details from kubectl:" >&2
    echo "--- kubectl get namespace $NS ---" >&2
    "${KUBECTL[@]}" get namespace "$NS" -o name 2>&1 | sed 's/^/  /' >&2 || true
    echo "--- kubectl get pods -n $NS ---" >&2
    "${KUBECTL[@]}" get pods -n "$NS" --request-timeout=20s 2>&1 | sed 's/^/  /' >&2 || true
    exit 3
  fi
fi

discover_master_svc() {
  local s
  for s in $("${KUBECTL[@]}" get svc -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if [[ "$s" == *master* ]]; then
      printf '%s' "$s"
      return 0
    fi
  done
  return 1
}

discover_filer_svc() {
  local s
  for s in $("${KUBECTL[@]}" get svc -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "$s" == *filer* ]] || continue
    [[ "$s" == *s3* ]] && continue
    [[ "$s" == *sync* ]] && continue
    printf '%s' "$s"
    return 0
  done
  return 1
}

MASTER_SVC="${SEAWEED_MASTER_SVC:-}"
[[ -n "$MASTER_SVC" ]] || MASTER_SVC="$(discover_master_svc || true)"
FILER_SVC="${SEAWEED_FILER_SVC:-}"
[[ -n "$FILER_SVC" ]] || FILER_SVC="$(discover_filer_svc || true)"

echo "== SeaweedFS health (namespace=${NS}) =="
echo "Detected services: master='${MASTER_SVC:-?}' filer='${FILER_SVC:-?}'"
echo ""

pick_filer_pod() {
  local p ready phase
  for p in $("${KUBECTL[@]}" get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "$p" == *filer* ]] || continue
    [[ "$p" == *filer-sync* ]] && continue
    [[ "$p" == *s3* ]] && continue
    phase=$("${KUBECTL[@]}" get pod -n "$NS" "$p" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase" == "Running" ]] || continue
    ready=$("${KUBECTL[@]}" get pod -n "$NS" "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$ready" == "True" ]] || continue
    printf '%s' "$p"
    return 0
  done
  return 1
}

FILER_POD="$(pick_filer_pod || true)"
if [[ -z "$FILER_POD" ]]; then
  echo "CRITICAL: no Running/Ready filer pod found in ${NS} (name contains 'filer', excludes s3/sync)." >&2
  bump_exit 2
  echo "(listing pods for debugging)"
  "${KUBECTL[@]}" get pods -n "$NS" -o wide || true
  exit "$MAX_EXIT"
fi

echo "Using filer pod: ${FILER_POD}"
filer_exec() {
  local -a extra=()
  [[ -n "${FILER_CONTAINER:-}" ]] && extra=(-c "$FILER_CONTAINER")
  "${KUBECTL[@]}" exec -n "$NS" "${extra[@]}" "$FILER_POD" -- sh -lc "$1"
}

http_get() {
  # $1 = URL path or full URL; prefers wget, falls back to curl inside filer image.
  local url="$1"
  filer_exec "if command -v wget >/dev/null 2>&1; then wget -qO- --timeout=${CURL_TIMEOUT} '${url}'; elif command -v curl >/dev/null 2>&1; then curl -fsS --max-time ${CURL_TIMEOUT} '${url}'; else echo 'no wget/curl in filer image' >&2; exit 4; fi"
}

echo ""
echo "-- Filer HTTP (localhost:8888) --"
if ! out="$(http_get 'http://127.0.0.1:8888/healthz' 2>/dev/null)"; then
  echo "CRITICAL: filer /healthz request failed (filer store / liveness)." >&2
  bump_exit 2
else
  echo "filer /healthz: OK (${#out} bytes body)"
fi

if out="$(http_get 'http://127.0.0.1:8888/status' 2>/dev/null)"; then
  echo "filer /status (first 800 chars):"
  printf '%s' "$out" | head -c 800
  echo ""
else
  echo "WARN: filer /status not reachable (older image or path); continuing." >&2
  bump_exit 1
fi

if [[ -n "$MASTER_SVC" ]]; then
  echo ""
  echo "-- Master (${MASTER_SVC}:9333) --"
  if ! http_get "http://${MASTER_SVC}:9333/cluster/healthz" >/dev/null 2>&1; then
    echo "CRITICAL: master /cluster/healthz failed." >&2
    bump_exit 2
  else
    echo "master /cluster/healthz: OK"
  fi

  if dir_json="$(http_get "http://${MASTER_SVC}:9333/dir/status?pretty=y" 2>/dev/null)"; then
    echo "master /dir/status: fetched"
    if command -v python3 >/dev/null 2>&1; then
      py_status=0
      set +e
      printf '%s' "$dir_json" | python3 - "$WARN_PCT" "$MIN_FREE_SLOTS" <<'PY'
import json, sys
warn_pct = int(sys.argv[1])
min_free = int(sys.argv[2])
raw = sys.stdin.read()
try:
    j = json.loads(raw)
except json.JSONDecodeError as e:
    print("WARN: could not parse /dir/status JSON:", e)
    sys.exit(0)
top = j.get("Topology") or {}
free = top.get("Free")
maxv = top.get("Max")
if free is None or maxv is None:
    print("WARN: Topology.Free/Max missing in /dir/status")
    sys.exit(0)
used_pct = int(round(100.0 * (maxv - free) / max(maxv, 1)))
print(f"Writable volume slots: free={free} max={maxv} (~{used_pct}% slots in use)")
if free <= 0:
    print("CRITICAL: no free writable volume slots — cluster cannot allocate new volumes.")
    sys.exit(2)
if free <= min_free:
    print(f"WARN: free slots {free} <= threshold {min_free}")
    sys.exit(1)
if used_pct >= warn_pct:
    print(f"WARN: slot utilization ~{used_pct}% >= {warn_pct}%")
    sys.exit(1)
print("Slot headroom: OK")
PY
      py_status=${PIPESTATUS[1]}
      set -e
      if (( py_status == 2 )); then bump_exit 2; elif (( py_status == 1 )); then bump_exit 1; fi
    else
      echo "WARN: python3 not installed; paste Topology.Free/Max manually from:"
      echo "$dir_json" | head -c 1200
      echo ""
      bump_exit 1
    fi
  else
    echo "CRITICAL: could not fetch master /dir/status" >&2
    bump_exit 2
  fi
else
  echo ""
  echo "WARN: master service not detected; skipped master checks." >&2
  bump_exit 1
fi

df_report_pod() {
  local pod="$1" role="$2"
  local out pct path line used
  echo ""
  echo "-- df (${role}: ${pod}) --"
  if ! out=$("${KUBECTL[@]}" exec -n "$NS" "$pod" -- sh -lc 'df -P 2>/dev/null || df' 2>/dev/null); then
    echo "WARN: could not run df in ${pod}" >&2
    bump_exit 1
    return
  fi
  echo "$out"
  while IFS= read -r line; do
    [[ "$line" == Filesystem* ]] && continue
    [[ -z "$line" ]] && continue
    fs=$(awk '{print $1}' <<<"$line")
    case "$fs" in
      tmpfs|devtmpfs|proc|sysfs|cgroup*|none) continue ;;
    esac
    pct=$(awk '{print $5}' <<<"$line" | tr -d '%' || true)
    path=$(awk '{print $6}' <<<"$line" || true)
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
      used=$((10#$pct))
      if (( used >= CRIT_PCT )); then
        echo "CRITICAL: ${role} ${pod} mount ${path:-?} at ${used}% used (threshold ${CRIT_PCT}%)" >&2
        bump_exit 2
      elif (( used >= WARN_PCT )); then
        echo "WARN: ${role} ${pod} mount ${path:-?} at ${used}% used (threshold ${WARN_PCT}%)" >&2
        bump_exit 1
      fi
    fi
  done <<<"$out"
}

echo ""
echo "-- Volume server disks (df inside each *volume* pod) --"
vol_found=0
for p in $("${KUBECTL[@]}" get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "$p" == *volume* ]] || continue
  phase=$("${KUBECTL[@]}" get pod -n "$NS" "$p" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Running" ]] || continue
  vol_found=1
  df_report_pod "$p" "volume"
done
if (( vol_found == 0 )); then
  echo "WARN: no Running pods with 'volume' in the name; skipped volume df." >&2
  bump_exit 1
fi

echo ""
echo "-- Filer pod disks (metadata / local volumes) --"
df_report_pod "$FILER_POD" "filer"

echo ""
echo "Summary: worst exit level ${MAX_EXIT} (0=ok, 1=warn, 2=critical)"
exit "$MAX_EXIT"

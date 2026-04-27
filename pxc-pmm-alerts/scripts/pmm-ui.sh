#!/usr/bin/env bash
# Open PMM web UI locally: preflight, then port-forward (foreground; blocks until Ctrl-C).
# Run from repo: ./scripts/pmm-k3d-ensure.sh && ./scripts/install-pmm-k3d.sh
set -euo pipefail

PMM_NS="${PMM_NS:-pmm}"
SVC="monitoring-service"
LOCAL_PORT="${PMM_LOCAL_PORT:-8443}"
# Chart exposes Service port name "https" (numeric 443); using the name avoids confusion with NodePort.
REL="${REL:-pmm}"
CTX="${KUBECTL_CONTEXT:-}"
CLUSTER="${K3D_CLUSTER:-pmm-local}"
DEFAULT_CTX="k3d-${CLUSTER}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need kubectl

if [[ -z "$CTX" ]]; then
  CTX="$DEFAULT_CTX"
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX"; then
    if kubectl config current-context 2>/dev/null | grep -q .; then
      CTX="$(kubectl config current-context)"
      echo "[pmm-ui] KUBECTL_CONTEXT unset; using current context: ${CTX}"
    else
      echo "[pmm-ui] No kubectl context. Run: ./scripts/pmm-k3d-ensure.sh" >&2
      exit 1
    fi
  fi
fi

if ! kubectl --context "$CTX" --request-timeout=15s get ns "$PMM_NS" >/dev/null 2>&1; then
  echo "[pmm-ui] namespace ${PMM_NS} not found on context ${CTX}. Run: ./scripts/pmm-k3d-ensure.sh && ./scripts/install-pmm-k3d.sh" >&2
  exit 1
fi

if ! kubectl --context "$CTX" --request-timeout=15s get svc -n "$PMM_NS" "$SVC" >/dev/null 2>&1; then
  echo "[pmm-ui] Service ${SVC} missing in ${PMM_NS}. Run: ./scripts/install-pmm-k3d.sh" >&2
  exit 1
fi

# No endpoints => PMM pod not ready; port-forward can appear to "hang" before forwarding starts.
EP="$(kubectl --context "$CTX" --request-timeout=15s get endpoints -n "$PMM_NS" "$SVC" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null | tr -d '\n' | head -c1)"
if [[ -z "$EP" ]]; then
  echo "[pmm-ui] ${SVC} has no endpoints (PMM not Running/Ready yet). Check: kubectl --context $CTX -n $PMM_NS get pods -o wide" >&2
  exit 1
fi

POD="$(kubectl --context "$CTX" --request-timeout=15s get pods -n "$PMM_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$POD" ]]; then
  READY="$(kubectl --context "$CTX" --request-timeout=15s get pod -n "$PMM_NS" "$POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$READY" != "True" ]]; then
    echo "[pmm-ui] PMM pod ${POD} is not Ready yet (${READY:-unknown}). Wait and retry, or: kubectl --context $CTX -n $PMM_NS describe pod $POD" >&2
    exit 1
  fi
fi

echo "[pmm-ui] https://127.0.0.1:${LOCAL_PORT}/  (user: admin)"
echo "[pmm-ui] password: kubectl --context $CTX get secret ${REL}-secret -n $PMM_NS -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 -d; echo"
echo "[pmm-ui] port-forward (blocks; Ctrl-C to stop)..."
exec kubectl --context "$CTX" port-forward -n "$PMM_NS" --address 127.0.0.1 "svc/${SVC}" "${LOCAL_PORT}:https"

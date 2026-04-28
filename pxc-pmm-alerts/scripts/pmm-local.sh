#!/usr/bin/env bash
# Single entrypoint: npm test, k3d + PMM (Helm), rebuild pxc-pmm-alerts-controller image, import into k3d,
# apply Nix k8s manifest, rollout restart + wait for controller Deployment, then HTTPS port-forward (blocks).
# macOS: uses Colima only — switches `docker context` to `colima` and clears DOCKER_HOST if it points elsewhere.
# Set PMM_LOCAL_ALLOW_NON_COLIMA=1 on macOS to skip that (not recommended).
# If the engine is not up: tries `colima start` once (disable with PMM_LOCAL_AUTO_COLIMA=0).
# If still unavailable, exits 0 after tests pass (skip k3d/PMM) unless PMM_LOCAL_REQUIRE_DOCKER=1 (use in CI).
# If PMM_LOCAL_PORT (default 8443) is in use, scans up to PMM_LOCAL_PORT + PMM_LOCAL_PORT_SCAN (default 40).
# Set PMM_LOCAL_SKIP_CONTROLLER=1 to skip docker build / nix-build / controller apply (PMM + port-forward only).
# Set PMM_LOCAL_TEST_ONLY=1 to run npm test and exit (no Docker/k3d).
# CLI:
#   --rebuild / --build : full workflow (tests + infra reconcile + controller build/deploy + port-forward).
#   no flags            : fast path, assumes stack already exists and only re-establishes port-forward.
#
# Per repo Cursor rules (.cursor/rules/percona-operator.mdc): kubectl blocking waits use 30s slices.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[pmm-local] missing: $1" >&2; exit 1; }; }

CLUSTER="${K3D_CLUSTER:-pmm-local}"
CTX="${KUBECTL_CONTEXT:-k3d-${CLUSTER}}"
PMM_NS="${PMM_NS:-pmm}"
REL="${REL:-pmm}"
SVC="monitoring-service"

DOCKER_INFO_TIMEOUT="${DOCKER_INFO_TIMEOUT:-30}"
if [[ "${DOCKER_INFO_TIMEOUT}" =~ ^[0-9]+$ ]] && [[ "${DOCKER_INFO_TIMEOUT}" -gt 120 ]]; then
  DOCKER_INFO_TIMEOUT=120
fi
K3D_API_POLL_MAX="${K3D_API_POLL_MAX:-120}"
# k3d version / other short CLI probes (≤30s per project rules).
K3D_CLI_TIMEOUT="${K3D_CLI_TIMEOUT:-30}"
# Healthy k3d returns `k3d cluster list` almost immediately; a hang is almost always Docker/Colima.
K3D_CLUSTER_LIST_TIMEOUT="${K3D_CLUSTER_LIST_TIMEOUT:-5}"
if [[ ! "${K3D_CLUSTER_LIST_TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${K3D_CLUSTER_LIST_TIMEOUT}" -lt 1 ]]; then
  K3D_CLUSTER_LIST_TIMEOUT=5
fi

# macOS often has no GNU `timeout`; bare `docker info` can hang forever against a wedged daemon.
run_with_timeout() {
  local secs="$1"
  shift
  if [[ ! "${secs}" =~ ^[0-9]+$ ]] || [[ "${secs}" -lt 1 ]]; then
    echo "[pmm-local] internal error: bad run_with_timeout seconds=${secs}" >&2
    return 2
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${secs}" "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  local i=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${i}" -ge "${secs}" ]]; then
      echo "[pmm-local] timed out after ${secs}s: $*" >&2
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 124
    fi
    # No GNU timeout on PATH: surface progress so the script never looks hung.
    if [[ "${i}" -gt 0 ]] && [[ $((i % 5)) -eq 0 ]]; then
      echo "[pmm-local] still running… ${i}/${secs}s elapsed: $*" >&2
    fi
    sleep 1
    i=$((i + 1))
  done
  wait "${pid}"
}

# Project rule (.cursor/rules/percona-operator.mdc): status every 20s on long work.
run_with_status_heartbeat() {
  local interval="${PMM_LOCAL_HEARTBEAT_SEC:-20}"
  "$@" &
  local _wpid=$!
  (
    while kill -0 "${_wpid}" 2>/dev/null; do
      sleep "${interval}"
      kill -0 "${_wpid}" 2>/dev/null && echo "[pmm-local] heartbeat (${interval}s): still running → $*" >&2
    done
  ) &
  local _hbpid=$!
  wait "${_wpid}"
  local _wrc=$?
  kill "${_hbpid}" 2>/dev/null || true
  wait "${_hbpid}" 2>/dev/null || true
  return "${_wrc}"
}

CHART_REPO="${CHART_REPO:-https://percona.github.io/percona-helm-charts}"
IMAGE_TAG="${IMAGE_TAG:-3.5.0}"
ROLL_SLICE="${ROLL_SLICE:-30s}"
PMM_ROLLOUT_MAX_SLICES="${PMM_ROLLOUT_MAX_SLICES:-120}"
PMM_BOOTSTRAP_PASSWORD="${PMM_BOOTSTRAP_PASSWORD:-pmm-local-dev}"

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-pxc-pmm-alerts-controller:latest}"
CONTROLLER_DEPLOYMENT="${CONTROLLER_DEPLOYMENT:-pxc-pmm-alerts-controller}"
DEPLOY_ROLLOUT_MAX_SLICES="${DEPLOY_ROLLOUT_MAX_SLICES:-60}"
API_QUICK_TIMEOUT_SEC="${API_QUICK_TIMEOUT_SEC:-5}"
API_RECOVERY_MAX="${API_RECOVERY_MAX:-1}"
MIN_COLIMA_MEMORY_GIB="${MIN_COLIMA_MEMORY_GIB:-6}"
MODE_REBUILD=0

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild|--build)
        MODE_REBUILD=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage: pmm-local.sh [--rebuild|--build]

  --rebuild, --build   Full workflow: tests + Docker/k3d/PMM/controller reconcile + port-forward.
  (no flags)           Fast path: verify existing stack and start port-forward only.
EOF
        exit 0
        ;;
      *)
        echo "[pmm-local] unknown argument: $1" >&2
        echo "[pmm-local] use --help for usage" >&2
        exit 2
        ;;
    esac
  done
}

require_positive_int_or_default() {
  local name="$1"
  local current="$2"
  local fallback="$3"
  if [[ ! "${current}" =~ ^[0-9]+$ ]] || [[ "${current}" -lt 1 ]]; then
    echo "[pmm-local] invalid ${name}='${current}', using ${fallback}"
    printf '%s' "${fallback}"
    return 0
  fi
  printf '%s' "${current}"
}

print_environment_contract() {
  echo "[pmm-local] ---- environment contract (verified before each stage) ----"
  echo "[pmm-local] required tools: npm, docker, k3d, kubectl, helm, nix-build"
  echo "[pmm-local] required container engine state: Docker daemon responsive via Colima context on macOS"
  echo "[pmm-local] required Colima capacity on macOS: memory >= ${MIN_COLIMA_MEMORY_GIB}GiB"
  echo "[pmm-local] required cluster state: k3d cluster '${CLUSTER}' exists and kubectl context '${CTX}' reaches API"
  echo "[pmm-local] required PMM state: namespace '${PMM_NS}', release '${REL}', and Service '${SVC}' with endpoints"
}

preflight_required_tools() {
  echo "[pmm-local] preflight: verifying required CLI tools are installed…"
  need npm
  need docker
  need k3d
  need kubectl
  need helm
  need nix-build
}

docker_ok() {
  local _quiet="${1:-}"
  [[ -z "${_quiet}" ]] && echo "[pmm-local] probing Docker engine: docker info (≤${DOCKER_INFO_TIMEOUT}s)…"
  run_with_timeout "${DOCKER_INFO_TIMEOUT}" docker info >/dev/null 2>&1
}

# After docker info succeeds: fail fast if k3d cannot talk to Docker (before cluster create/start).
preflight_k3d_bridge() {
  echo "[pmm-local] preflight: k3d can reach Docker (k3d version, ≤${K3D_CLI_TIMEOUT}s)…"
  if ! run_with_timeout "${K3D_CLI_TIMEOUT}" k3d version >/dev/null 2>&1; then
    echo "[pmm-local] FAIL: k3d cannot use Docker — Colima/docker.sock may be down. Run: colima start && docker info" >&2
    exit 1
  fi
  echo "[pmm-local] preflight: k3d ↔ Docker OK."
}

# Foreground `colima start` with periodic heartbeats (first boot can take minutes).
colima_start_with_heartbeat() {
  echo "[pmm-local] colima start $* (first boot can take minutes; heartbeat every ${PMM_LOCAL_HEARTBEAT_SEC:-20}s)…"
  colima start "$@" &
  local _cpid=$!
  while kill -0 "${_cpid}" 2>/dev/null; do
    sleep "${PMM_LOCAL_HEARTBEAT_SEC:-20}"
    if kill -0 "${_cpid}" 2>/dev/null; then
      echo "[pmm-local] colima start still running…"
    fi
  done
  wait "${_cpid}" || true
}

colima_current_memory_gib() {
  colima list 2>/dev/null | awk 'NR>1 && $1=="default" { gsub(/GiB/, "", $5); print $5; exit }'
}

ensure_colima_capacity() {
  case "$(uname -s)" in
    Darwin) ;;
    *) return 0 ;;
  esac
  [[ "${PMM_LOCAL_ALLOW_NON_COLIMA:-0}" == "1" ]] && return 0
  command -v colima >/dev/null 2>&1 || return 0

  local current_mem
  current_mem="$(colima_current_memory_gib)"
  if [[ -z "${current_mem}" ]] || [[ ! "${current_mem}" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if [[ "${current_mem}" -ge "${MIN_COLIMA_MEMORY_GIB}" ]]; then
    return 0
  fi

  echo "[pmm-local] Colima memory ${current_mem}GiB is below required ${MIN_COLIMA_MEMORY_GIB}GiB for PMM; resizing."
  if [[ "${PMM_LOCAL_AUTO_COLIMA:-1}" == "0" ]] || [[ "${PMM_LOCAL_AUTO_COLIMA:-}" == "false" ]]; then
    echo "[pmm-local] PMM_LOCAL_AUTO_COLIMA=0 and Colima is under-provisioned; restart with at least ${MIN_COLIMA_MEMORY_GIB}GiB." >&2
    exit 1
  fi

  echo "[pmm-local] recovery: colima stop (≤10s) for resize…" >&2
  run_with_timeout 10 colima stop >/dev/null 2>&1 || true
  colima_start_with_heartbeat --memory "${MIN_COLIMA_MEMORY_GIB}"
  current_mem="$(colima_current_memory_gib)"
  if [[ -z "${current_mem}" ]] || [[ ! "${current_mem}" =~ ^[0-9]+$ ]] || [[ "${current_mem}" -lt "${MIN_COLIMA_MEMORY_GIB}" ]]; then
    echo "[pmm-local] FAIL: Colima memory is still ${current_mem:-unknown}GiB after resize attempt; required >= ${MIN_COLIMA_MEMORY_GIB}GiB." >&2
    echo "[pmm-local] Run: colima stop && colima start --memory ${MIN_COLIMA_MEMORY_GIB}" >&2
    exit 1
  fi
}

maybe_start_colima() {
  [[ "${PMM_LOCAL_AUTO_COLIMA:-1}" == "0" ]] && return 1
  command -v colima >/dev/null 2>&1 || return 1
  echo "[pmm-local] Colima engine did not respond to docker info; will run: colima start"
  colima_start_with_heartbeat
}

# When `k3d cluster list` hangs, Docker's API is often wedged while `k3d version` still returns.
recover_after_k3d_cluster_list_hang() {
  echo "[pmm-local] k3d cluster list hung (>${K3D_CLUSTER_LIST_TIMEOUT}s) — attempting Colima/Docker recovery…" >&2

  if [[ "${PMM_LOCAL_AUTO_COLIMA:-1}" == "0" ]] || [[ "${PMM_LOCAL_AUTO_COLIMA:-}" == "false" ]]; then
    echo "[pmm-local] PMM_LOCAL_AUTO_COLIMA=0 — restart Colima/Docker yourself, then retry." >&2
    return 1
  fi

  case "$(uname -s)" in
    Darwin) ;;
    *)
      echo "[pmm-local] Restart the container engine (Docker/Colima) and retry." >&2
      return 1
      ;;
  esac

  if [[ "${PMM_LOCAL_ALLOW_NON_COLIMA:-0}" == "1" ]] || ! command -v colima >/dev/null 2>&1; then
    echo "[pmm-local] No Colima on PATH (or PMM_LOCAL_ALLOW_NON_COLIMA=1) — restart Docker and retry." >&2
    return 1
  fi

  echo "[pmm-local] recovery: colima stop (≤10s)…" >&2
  run_with_timeout 10 colima stop >/dev/null 2>&1 || true

  colima_start_with_heartbeat

  ensure_colima_docker_context
  if ! docker_ok quiet; then
    echo "[pmm-local] recovery: docker info still failing after colima restart." >&2
    return 1
  fi

  echo "[pmm-local] recovery: Docker OK — retrying k3d cluster list…" >&2
  return 0
}

# On macOS, force the Docker CLI to use Colima's socket (not Docker Desktop / DOCKER_HOST).
ensure_colima_docker_context() {
  [[ "${PMM_LOCAL_ALLOW_NON_COLIMA:-0}" == "1" ]] && return 0
  case "$(uname -s)" in
    Darwin) ;;
    *) return 0 ;;
  esac

  need docker
  if ! command -v colima >/dev/null 2>&1; then
    echo "[pmm-local] On macOS this script expects Colima (brew install colima). Set PMM_LOCAL_ALLOW_NON_COLIMA=1 to opt out." >&2
    exit 1
  fi
  ensure_colima_capacity

  echo "[pmm-local] Docker: docker context ls (≤${DOCKER_INFO_TIMEOUT}s)…"
  local _clist_rc=0
  local _clist_out
  _clist_out="$(run_with_timeout "${DOCKER_INFO_TIMEOUT}" docker context ls --format '{{.Name}}' 2>/dev/null)" || _clist_rc=$?
  if [[ "${_clist_rc}" -eq 124 ]]; then
    echo "[pmm-local] docker context ls timed out — the daemon behind your Docker socket is stuck. Try: colima stop && colima start" >&2
    exit 1
  fi

  if ! grep -qx colima <<<"${_clist_out}"; then
    echo "[pmm-local] No Docker context named 'colima'. Run: brew install colima && colima start" >&2
    exit 1
  fi

  local cur="" _show_rc=0
  echo "[pmm-local] Docker: docker context show (≤${DOCKER_INFO_TIMEOUT}s)…"
  cur="$(run_with_timeout "${DOCKER_INFO_TIMEOUT}" docker context show 2>/dev/null)" || _show_rc=$?
  if [[ "${_show_rc}" -eq 124 ]]; then
    echo "[pmm-local] docker context show timed out — fix Colima/Docker socket, then retry." >&2
    exit 1
  fi

  if [[ "${cur}" != "colima" ]]; then
    echo "[pmm-local] switching Docker context '${cur:-unknown}' → colima (${DOCKER_INFO_TIMEOUT}s max)…"
    if ! run_with_timeout "${DOCKER_INFO_TIMEOUT}" docker context use colima; then
      echo "[pmm-local] docker context use colima failed or timed out." >&2
      exit 1
    fi
  fi

  if [[ -n "${DOCKER_HOST:-}" ]] && [[ "${DOCKER_HOST}" != *".colima/"* ]]; then
    echo "[pmm-local] unsetting DOCKER_HOST so Colima's context wins (was ${DOCKER_HOST})"
    unset DOCKER_HOST
  fi
}

ensure_k3d() {
  need docker
  need k3d
  need kubectl

  local ctx="k3d-${CLUSTER}"

  echo "[pmm-local] k3d: listing clusters (≤${K3D_CLUSTER_LIST_TIMEOUT}s; hang ⇒ wedged Docker API, not slow k3d)…"
  local _lr=0
  local _k3d_list=""
  local _recovery_attempted=0

  while true; do
    _lr=0
    _k3d_list="$(run_with_timeout "${K3D_CLUSTER_LIST_TIMEOUT}" k3d cluster list 2>/dev/null)" || _lr=$?
    if [[ "${_lr}" -ne 124 ]]; then
      break
    fi
    if [[ "${_recovery_attempted}" -eq 1 ]]; then
      echo "[pmm-local] FAIL: k3d cluster list still hung after recovery — try: colima stop && colima start; or k3d cluster delete ${CLUSTER}" >&2
      exit 1
    fi
    _recovery_attempted=1
    if ! recover_after_k3d_cluster_list_hang; then
      exit 1
    fi
    preflight_k3d_bridge
  done

  if printf '%s\n' "${_k3d_list}" | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; then
    echo "[pmm-local] k3d: cluster '${CLUSTER}' exists — starting it (k3d --wait --timeout 30s; heartbeats every ${PMM_LOCAL_HEARTBEAT_SEC:-20}s if slow)…"
    if ! run_with_status_heartbeat k3d cluster start "$CLUSTER" --wait --timeout 30s; then
      echo "[pmm-local] FAIL: k3d cluster start returned error; refusing to continue on assumed state." >&2
      exit 1
    fi
    echo "[pmm-local] k3d: cluster start finished."
  else
    echo "[pmm-local] k3d: creating cluster '${CLUSTER}' (--wait=false; then API polling; heartbeats while create runs)…"
    run_with_status_heartbeat k3d cluster create "$CLUSTER" --wait=false
    echo "[pmm-local] k3d: cluster create finished."
  fi

  echo "[pmm-local] k3d: merging kubeconfig and switching kubectl context → ${ctx}"
  run_with_timeout "${K3D_CLI_TIMEOUT}" k3d kubeconfig merge "$CLUSTER" --kubeconfig-merge-default --kubeconfig-switch-context

  echo "[pmm-local] Kubernetes: polling API until ready (≤${K3D_API_POLL_MAX} attempts, 2s apart)…"
  local _poll=0
  while [[ "${_poll}" -lt "${K3D_API_POLL_MAX}" ]]; do
    _poll=$((_poll + 1))
    if kubectl --request-timeout=30s --context "${ctx}" cluster-info >/dev/null 2>&1; then
      echo "[pmm-local] Kubernetes API ready (poll ${_poll}/${K3D_API_POLL_MAX})"
      return 0
    fi
    echo "[pmm-local] Kubernetes API not ready yet (poll ${_poll}/${K3D_API_POLL_MAX})…"
    kubectl --request-timeout=30s --context "${ctx}" get nodes -o wide 2>/dev/null || true
    sleep 2
  done

  echo "[pmm-local] kubectl cannot reach the API after ${K3D_API_POLL_MAX} polls. Try: k3d cluster delete ${CLUSTER} && $0" >&2
  exit 1
}

verify_cluster_contract() {
  echo "[pmm-local] preflight: verifying k3d cluster '${CLUSTER}' and kubectl context '${CTX}' are usable…"
  if ! run_with_timeout "${K3D_CLUSTER_LIST_TIMEOUT}" k3d cluster list >/dev/null 2>&1; then
    echo "[pmm-local] preflight: k3d cluster list hung during contract check; invoking recovery."
    recover_after_k3d_cluster_list_hang || {
      echo "[pmm-local] FAIL: cannot recover k3d/docker contract." >&2
      exit 1
    }
  fi
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CTX}"; then
    echo "[pmm-local] preflight: context ${CTX} missing; forcing kubeconfig merge from k3d."
    run_with_timeout "${K3D_CLI_TIMEOUT}" k3d kubeconfig merge "${CLUSTER}" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null
  fi
}

# Fast API sanity check to catch TLS handshake stalls early.
kube_api_quick_probe() {
  local _out _rc=0
  _out="$(kubectl --context "${CTX}" --request-timeout="${API_QUICK_TIMEOUT_SEC}s" cluster-info 2>&1)" || _rc=$?
  if [[ "${_rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${_out}" == *"TLS handshake timeout"* ]] || [[ "${_out}" == *"i/o timeout"* ]] || [[ "${_out}" == *"context deadline exceeded"* ]]; then
    return 42
  fi
  return 1
}

recover_kube_api_instability() {
  echo "[pmm-local] API probe unstable (TLS/timeout) — repairing cluster runtime…" >&2
  preflight_k3d_bridge

  echo "[pmm-local] recovery: k3d cluster stop ${CLUSTER} (≤30s)…" >&2
  run_with_timeout 30 k3d cluster stop "${CLUSTER}" >/dev/null 2>&1 || true

  echo "[pmm-local] recovery: k3d cluster start ${CLUSTER} (≤30s + heartbeat)…" >&2
  if ! run_with_status_heartbeat k3d cluster start "${CLUSTER}" --wait --timeout 30s; then
    echo "[pmm-local] recovery: k3d cluster start failed." >&2
    return 1
  fi

  echo "[pmm-local] recovery: re-merge kubeconfig for ${CLUSTER}…" >&2
  if ! run_with_timeout "${K3D_CLI_TIMEOUT}" k3d kubeconfig merge "${CLUSTER}" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null; then
    echo "[pmm-local] recovery: kubeconfig merge failed." >&2
    return 1
  fi

  verify_cluster_contract
  kube_api_quick_probe
}

# Return 0 if something is listening on 127.0.0.1:port (TCP).
tcp_listen_busy() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" 2>/dev/null
    return $?
  fi
  return 1
}

# First free port in [base, base + PMM_LOCAL_PORT_SCAN]; no lsof/nc => use base as-is.
pick_local_port() {
  local base="$1"
  local max_scan="${PMM_LOCAL_PORT_SCAN:-40}"
  echo "[pmm-local] scanning 127.0.0.1 TCP ports starting at ${base} (up to ${max_scan} tries)…" >&2
  local p end
  if ! command -v lsof >/dev/null 2>&1 && ! command -v nc >/dev/null 2>&1; then
    echo "[pmm-local] no lsof/nc — using base port ${base}" >&2
    echo "$base"
    return 0
  fi
  end=$((base + max_scan))
  for ((p = base; p <= end; p++)); do
    if ! tcp_listen_busy "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "[pmm-local] TCP ports ${base}-${end} in use on 127.0.0.1. Stop the other listener, set PMM_LOCAL_PORT to a free port, or widen the search with PMM_LOCAL_PORT_SCAN." >&2
  exit 1
}

install_pmm() {
  need kubectl
  need helm

  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CTX}"; then
    echo "[pmm-local] kubectl context \"${CTX}\" not found (run failed before ensure?)." >&2
    exit 1
  fi

  echo "[pmm-local] PMM Helm: using context ${CTX}"

  echo "[pmm-local] PMM Helm: ensuring namespace ${PMM_NS}…"
  kubectl --context "${CTX}" create namespace "${PMM_NS}" --dry-run=client -o yaml | kubectl --context "${CTX}" apply -f - --request-timeout=30s

  echo "[pmm-local] PMM Helm: helm upgrade --install chart 'pmm' release '${REL}' (chart download can take time)…"
  local _helm_tmp
  _helm_tmp="$(mktemp -d)"
  (cd "${_helm_tmp}" && run_with_status_heartbeat helm upgrade --install "${REL}" pmm \
    --kube-context "${CTX}" \
    --repo "${CHART_REPO}" \
    --namespace "${PMM_NS}" \
    --set service.type=ClusterIP \
    --set image.tag="${IMAGE_TAG}" \
    --set secret.pmm_password="${PMM_BOOTSTRAP_PASSWORD}")
  rm -rf "${_helm_tmp}"
  echo "[pmm-local] PMM Helm: helm install/upgrade finished."

  if ! kubectl --context "${CTX}" get secret "${REL}-secret" -n "${PMM_NS}" --request-timeout=30s &>/dev/null; then
    echo "[pmm-local] PMM: creating secret ${REL}-secret…"
    kubectl --context "${CTX}" create secret generic "${REL}-secret" -n "${PMM_NS}" \
      --from-literal=PMM_ADMIN_PASSWORD="${PMM_BOOTSTRAP_PASSWORD}" \
      --request-timeout=30s
  fi

  echo "[pmm-local] PMM: waiting for StatefulSet/${REL} rollout (${ROLL_SLICE} per kubectl wait, max ${PMM_ROLLOUT_MAX_SLICES} waits)…"
  local _slice=0
  local _api_recovers=0
  until kubectl --context "${CTX}" rollout status "statefulset/${REL}" -n "${PMM_NS}" --timeout="${ROLL_SLICE}" --request-timeout=30s; do
    _slice=$((_slice + 1))
    if [[ "${_slice}" -ge "${PMM_ROLLOUT_MAX_SLICES}" ]]; then
      echo "[pmm-local] rollout not finished after ${PMM_ROLLOUT_MAX_SLICES} slices. Re-run this script." >&2
      exit 1
    fi
    echo "[pmm-local] PMM rollout wait slice ${_slice}/${PMM_ROLLOUT_MAX_SLICES} (StatefulSet not ready yet)…"
    local _probe_rc=0
    kube_api_quick_probe || _probe_rc=$?
    if [[ "${_probe_rc}" -eq 42 ]] && [[ "${_api_recovers}" -lt "${API_RECOVERY_MAX}" ]]; then
      _api_recovers=$((_api_recovers + 1))
      echo "[pmm-local] API TLS timeout detected during PMM rollout — recovery attempt ${_api_recovers}/${API_RECOVERY_MAX}."
      if recover_kube_api_instability; then
        continue
      fi
    fi
    kubectl --context "${CTX}" get pods -n "${PMM_NS}" -o wide --request-timeout=30s || true
  done

  echo "[pmm-local] PMM admin password (secret ${REL}-secret):"
  kubectl --context "${CTX}" get secret "${REL}-secret" -n "${PMM_NS}" -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' --request-timeout=30s | base64 -d
  echo ""
}

preflight_port_forward() {
  need kubectl

  echo "[pmm-local] port-forward preflight: checking namespace ${PMM_NS}…"
  if ! kubectl --context "${CTX}" --request-timeout=30s get ns "${PMM_NS}" >/dev/null 2>&1; then
    echo "[pmm-local] namespace ${PMM_NS} not found on ${CTX}." >&2
    exit 1
  fi

  echo "[pmm-local] port-forward preflight: checking Service ${SVC}…"
  if ! kubectl --context "${CTX}" --request-timeout=30s get svc -n "${PMM_NS}" "${SVC}" >/dev/null 2>&1; then
    echo "[pmm-local] Service ${SVC} missing in ${PMM_NS}." >&2
    exit 1
  fi

  echo "[pmm-local] port-forward preflight: checking Endpoints for ${SVC} (pods must be scheduling)…"
  local ep
  ep="$(kubectl --context "${CTX}" --request-timeout=30s get endpoints -n "${PMM_NS}" "${SVC}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null | tr -d '\n' | head -c1)"
  if [[ -z "${ep}" ]]; then
    echo "[pmm-local] ${SVC} has no endpoints (PMM not ready). kubectl --context ${CTX} -n ${PMM_NS} get pods" >&2
    exit 1
  fi

  echo "[pmm-local] port-forward preflight: checking PMM pod Ready…"
  local pod ready
  pod="$(kubectl --context "${CTX}" --request-timeout=30s get pods -n "${PMM_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    ready="$(kubectl --context "${CTX}" --request-timeout=30s get pod -n "${PMM_NS}" "${pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" != "True" ]]; then
      echo "[pmm-local] PMM pod ${pod} not Ready (${ready:-unknown})." >&2
      exit 1
    fi
  fi
  echo "[pmm-local] port-forward preflight: OK (namespace, Service, Endpoints, Ready)"
}

run_tests() {
  need npm
  echo "[pmm-local] running unit tests: npm test (Vitest)…"
  npm test
  echo "[pmm-local] unit tests finished."
}

build_and_deploy_controller() {
  if [[ "${PMM_LOCAL_SKIP_CONTROLLER:-0}" == "1" ]] || [[ "${PMM_LOCAL_SKIP_CONTROLLER:-}" == "true" ]]; then
    echo "[pmm-local] skipping controller image + deploy (PMM_LOCAL_SKIP_CONTROLLER=1)"
    return 0
  fi

  need nix-build
  if ! docker buildx version >/dev/null 2>&1; then
    echo "[pmm-local] docker buildx is required (install: https://docs.docker.com/build/buildx/install/)" >&2
    exit 1
  fi

  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CTX}"; then
    echo "[pmm-local] kubectl context \"${CTX}\" not found." >&2
    exit 1
  fi

  echo "[pmm-local] controller: docker buildx build --load -t ${CONTROLLER_IMAGE} (streaming build log)…"
  docker buildx build --progress=plain --load -t "${CONTROLLER_IMAGE}" .

  echo "[pmm-local] controller: k3d image import ${CONTROLLER_IMAGE} → cluster ${CLUSTER} (heartbeats while importing)…"
  run_with_status_heartbeat k3d image import "${CONTROLLER_IMAGE}" -c "${CLUSTER}"
  echo "[pmm-local] controller: k3d image import finished."

  echo "[pmm-local] controller: nix-build pxc-pmm-alerts.nix -A k8sManifest (first run may fetch store paths; heartbeats)…"
  local _man
  _man="$(run_with_status_heartbeat nix-build pxc-pmm-alerts.nix -A k8sManifest --no-out-link)"
  echo "[pmm-local] controller: nix-build finished → ${_man}"

  echo "[pmm-local] controller: kubectl apply -f ${_man}"
  kubectl --context "${CTX}" apply -f "${_man}" --request-timeout=30s

  echo "[pmm-local] controller: kubectl rollout restart deployment/${CONTROLLER_DEPLOYMENT}"
  kubectl --context "${CTX}" -n "${PMM_NS}" rollout restart "deployment/${CONTROLLER_DEPLOYMENT}" \
    --request-timeout=30s 2>/dev/null || true

  echo "[pmm-local] controller: waiting for deployment/${CONTROLLER_DEPLOYMENT} (${ROLL_SLICE} per wait, max ${DEPLOY_ROLLOUT_MAX_SLICES})…"
  local _slice=0
  local _api_recovers=0
  until kubectl --context "${CTX}" -n "${PMM_NS}" rollout status "deployment/${CONTROLLER_DEPLOYMENT}" \
    --timeout="${ROLL_SLICE}" --request-timeout=30s; do
    _slice=$((_slice + 1))
    if [[ "${_slice}" -ge "${DEPLOY_ROLLOUT_MAX_SLICES}" ]]; then
      echo "[pmm-local] controller rollout not finished after ${DEPLOY_ROLLOUT_MAX_SLICES} slices of ${ROLL_SLICE}" >&2
      exit 1
    fi
    echo "[pmm-local] controller rollout wait ${_slice}/${DEPLOY_ROLLOUT_MAX_SLICES} (deployment not ready yet)…"
    local _probe_rc=0
    kube_api_quick_probe || _probe_rc=$?
    if [[ "${_probe_rc}" -eq 42 ]] && [[ "${_api_recovers}" -lt "${API_RECOVERY_MAX}" ]]; then
      _api_recovers=$((_api_recovers + 1))
      echo "[pmm-local] API TLS timeout detected during controller rollout — recovery attempt ${_api_recovers}/${API_RECOVERY_MAX}."
      if recover_kube_api_instability; then
        continue
      fi
    fi
    kubectl --context "${CTX}" get pods -n "${PMM_NS}" -o wide --request-timeout=30s || true
  done

  echo "[pmm-local] controller logs: kubectl --context ${CTX} -n ${PMM_NS} logs -f deploy/${CONTROLLER_DEPLOYMENT}"
}

# --- main ---
parse_cli_args "$@"

DOCKER_INFO_TIMEOUT="$(require_positive_int_or_default DOCKER_INFO_TIMEOUT "${DOCKER_INFO_TIMEOUT}" 30)"
K3D_CLI_TIMEOUT="$(require_positive_int_or_default K3D_CLI_TIMEOUT "${K3D_CLI_TIMEOUT}" 30)"
K3D_CLUSTER_LIST_TIMEOUT="$(require_positive_int_or_default K3D_CLUSTER_LIST_TIMEOUT "${K3D_CLUSTER_LIST_TIMEOUT}" 5)"
K3D_API_POLL_MAX="$(require_positive_int_or_default K3D_API_POLL_MAX "${K3D_API_POLL_MAX}" 120)"

print_environment_contract
preflight_required_tools

if [[ "${MODE_REBUILD}" -eq 0 ]]; then
  echo "[pmm-local] ---- fast mode: verify running stack and re-establish port-forward only ----"
  ensure_colima_docker_context
  if ! docker_ok quiet; then
    echo "[pmm-local] Docker/Colima is not healthy for fast mode. Re-run with --rebuild." >&2
    exit 1
  fi
  preflight_k3d_bridge
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CTX}"; then
    echo "[pmm-local] kubectl context ${CTX} is missing. Re-run with --rebuild." >&2
    exit 1
  fi
  if ! kubectl --context "${CTX}" --request-timeout=30s cluster-info >/dev/null 2>&1; then
    echo "[pmm-local] Kubernetes API for ${CTX} is unavailable. Re-run with --rebuild." >&2
    exit 1
  fi
else
  run_tests

  if [[ "${PMM_LOCAL_TEST_ONLY:-0}" == "1" ]] || [[ "${PMM_LOCAL_TEST_ONLY:-}" == "true" ]]; then
    echo "[pmm-local] PMM_LOCAL_TEST_ONLY=1 — skipping k3d/PMM/controller/port-forward."
    exit 0
  fi

  echo "[pmm-local] ---- step: Colima / Docker CLI (macOS forces context=colima; each docker invocation ≤ ${DOCKER_INFO_TIMEOUT}s) ----"
  ensure_colima_docker_context

  echo "[pmm-local] ---- step: verify Docker daemon responds (docker info) ----"
  if ! docker_ok; then
    echo "[pmm-local] docker info failed — will try to start Colima if allowed."
    maybe_start_colima
  fi

  if ! docker_ok quiet; then
    if [[ "${PMM_LOCAL_REQUIRE_DOCKER:-0}" == "1" ]] || [[ "${PMM_LOCAL_REQUIRE_DOCKER:-}" == "true" ]]; then
      echo "[pmm-local] Colima engine not responding within ${DOCKER_INFO_TIMEOUT}s (after colima start, if tried)." >&2
      echo "[pmm-local] Fix: colima stop && colima start   (then: docker info)" >&2
      exit 1
    fi
    echo "[pmm-local] Colima unavailable; skipping k3d, PMM, controller, and port-forward. Tests passed." >&2
    echo "[pmm-local] Start Colima and re-run for the full stack. CI: set PMM_LOCAL_REQUIRE_DOCKER=1 to fail here." >&2
    exit 0
  fi

  preflight_k3d_bridge

  echo "[pmm-local] ---- step: k3d cluster ${CLUSTER} + Kubernetes API ----"
  ensure_k3d
  verify_cluster_contract

  echo "[pmm-local] ---- step: Helm install PMM chart ----"
  install_pmm

  echo "[pmm-local] ---- step: build + deploy pxc-pmm-alerts-controller ----"
  build_and_deploy_controller
fi

echo "[pmm-local] ---- step: preflight before kubectl port-forward ----"
preflight_port_forward

REQUESTED_PORT="${PMM_LOCAL_PORT:-8443}"
echo "[pmm-local] ---- step: pick local TCP port (default ${REQUESTED_PORT}) ----"
LOCAL_PORT="$(pick_local_port "${REQUESTED_PORT}")"
if [[ "${LOCAL_PORT}" != "${REQUESTED_PORT}" ]]; then
  echo "[pmm-local] port ${REQUESTED_PORT} busy on 127.0.0.1; using ${LOCAL_PORT} (override with PMM_LOCAL_PORT)"
fi

echo "[pmm-local] In-cluster API base: https://monitoring-service.${PMM_NS}.svc.cluster.local"
echo "[pmm-local] Browser: https://127.0.0.1:${LOCAL_PORT}/  (user: admin)"
echo "[pmm-local] Password: kubectl --context ${CTX} get secret ${REL}-secret -n ${PMM_NS} -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 -d; echo"
echo "[pmm-local] ---- step: kubectl port-forward (foreground; Ctrl-C stops) svc/${SVC} :https → 127.0.0.1:${LOCAL_PORT} ----"
exec kubectl --context "${CTX}" port-forward -n "${PMM_NS}" --address 127.0.0.1 "svc/${SVC}" "${LOCAL_PORT}:https"

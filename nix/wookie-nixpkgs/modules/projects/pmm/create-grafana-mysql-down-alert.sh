#!/usr/bin/env bash
# Creates (or updates) a Grafana-managed "MySQL down" alert rule in PMM.
#
# Works from a WSL/Linux host with kubectl + curl. Uses kubectl port-forward
# to reach PMM's embedded Grafana over HTTP (port 80) - no helper pod needed.
#
# Environment variables (all optional - will prompt if missing):
#   KUBE_CONTEXT         kubernetes context (default: auto-detect k3d context)
#   PMM_NAMESPACE        namespace containing pmm-server (default: auto-detect)
#   PMM_ADMIN_PASSWORD   PMM admin password (default: prompts, falling back to "admin")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT_JSON="${SCRIPT_DIR}/grafana-mysql-down-alert.json"

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
PMM_NAMESPACE="${PMM_NAMESPACE:-}"
PMM_ADMIN_PASSWORD="${PMM_ADMIN_PASSWORD:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n'   "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
prompt_var() {
  local varname="$1" msg="$2" default="${3:-}"
  if [[ -n "${!varname:-}" ]]; then
    log "$varname = ${!varname}"
    return
  fi
  local val
  if [[ -n "$default" ]]; then
    read -rp "$msg [$default]: " val
    val="${val:-$default}"
  else
    read -rp "$msg: " val
    [[ -n "$val" ]] || die "$varname cannot be empty"
  fi
  printf -v "$varname" '%s' "$val"
}

prompt_secret() {
  local varname="$1" msg="$2" default="${3:-}"
  if [[ -n "${!varname:-}" ]]; then
    log "$varname already set from environment"
    return
  fi
  local val
  if [[ -n "$default" ]]; then
    read -rsp "$msg [$default]: " val; echo
    val="${val:-$default}"
  else
    read -rsp "$msg: " val; echo
    [[ -n "$val" ]] || die "$varname cannot be empty"
  fi
  printf -v "$varname" '%s' "$val"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  command -v kubectl >/dev/null 2>&1 || missing+=(kubectl)
  command -v curl    >/dev/null 2>&1 || missing+=(curl)
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"

  if command -v jq >/dev/null 2>&1; then
    JSON_TOOL="jq"
  elif command -v python3 >/dev/null 2>&1; then
    JSON_TOOL="python3"
  else
    JSON_TOOL="sed"
    warn "Neither jq nor python3 found - JSON parsing will be fragile"
  fi
  log "JSON tool: $JSON_TOOL"
}

# ---------------------------------------------------------------------------
# Kube context resolution
#
# Priority:
#   1. k3d contexts already in kubeconfig
#   2. k3d clusters found via `k3d cluster list` -> merge kubeconfig on the fly
#   3. Any context in kubeconfig (prompted)
#   4. Bare prompt
# ---------------------------------------------------------------------------
pick_context_from_list() {
  local -n _contexts=$1  # nameref to array
  local count=${#_contexts[@]}
  if [[ $count -eq 1 ]]; then
    KUBE_CONTEXT="${_contexts[0]}"
    log "Auto-selected context: $KUBE_CONTEXT"
  else
    log "Available contexts:"
    local i=0
    while [[ $i -lt $count ]]; do
      printf '  %d) %s\n' "$((i + 1))" "${_contexts[$i]}"
      i=$((i + 1))
    done
    prompt_var KUBE_CONTEXT "Kube context to use" "${_contexts[0]}"
  fi
}

resolve_context() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    log "KUBE_CONTEXT=$KUBE_CONTEXT"
    return
  fi

  # --- 1. k3d contexts already in kubeconfig ---
  local -a all_contexts=() k3d_contexts=()
  mapfile -t all_contexts < <(kubectl config get-contexts -o name 2>/dev/null || true)
  mapfile -t k3d_contexts < <(
    printf '%s\n' "${all_contexts[@]+"${all_contexts[@]}"}" | grep '^k3d-' || true)

  if [[ ${#k3d_contexts[@]} -gt 0 ]]; then
    pick_context_from_list k3d_contexts
    return
  fi

  # --- 2. k3d clusters not yet in kubeconfig ---
  # Rather than trying to merge into ~/.kube/config (which may not be what
  # kubectl is actually reading in WSL), pull the kubeconfig directly from
  # k3d, write it to a temp file, and prepend it to KUBECONFIG for this
  # process only. Nothing is permanently modified.
  if command -v k3d >/dev/null 2>&1; then
    local -a k3d_clusters=()
    mapfile -t k3d_clusters < <(
      k3d cluster list 2>/dev/null | awk 'NR>1 && $1!="" {print $1}' || true)

    if [[ ${#k3d_clusters[@]} -gt 0 ]]; then
      log "k3d clusters found (not yet in kubeconfig): ${k3d_clusters[*]}"

      local cluster
      if [[ ${#k3d_clusters[@]} -eq 1 ]]; then
        cluster="${k3d_clusters[0]}"
        log "Using k3d cluster: $cluster"
      else
        log "Multiple k3d clusters:"
        local i=0
        while [[ $i -lt ${#k3d_clusters[@]} ]]; do
          printf '  %d) %s\n' "$((i+1))" "${k3d_clusters[$i]}"
          i=$((i+1))
        done
        cluster="${k3d_clusters[0]}"
        prompt_var cluster "k3d cluster to use" "${k3d_clusters[0]}"
      fi

      local tmpkube
      tmpkube=$(mktemp /tmp/k3d-kubeconfig-XXXXXX.yaml)
      K3D_TMPKUBE="$tmpkube"  # picked up by cleanup()

      if k3d kubeconfig get "$cluster" > "$tmpkube" 2>/dev/null; then
        export KUBECONFIG="${tmpkube}:${KUBECONFIG:-${HOME}/.kube/config}"
        log "Injected k3d kubeconfig for cluster '$cluster'"
        KUBE_CONTEXT="k3d-${cluster}"
        log "Using context: $KUBE_CONTEXT"
        return
      else
        warn "k3d kubeconfig get '$cluster' failed"
        rm -f "$tmpkube"
        K3D_TMPKUBE=""
      fi
    fi
  fi

  # --- 3. Fall back to any available context ---
  if [[ ${#all_contexts[@]} -gt 0 ]]; then
    warn "No k3d contexts found. Showing all available contexts:"
    pick_context_from_list all_contexts
    return
  fi

  # --- 4. Nothing found - bare prompt ---
  warn "No kubectl contexts found at all. Is KUBECONFIG set correctly?"
  prompt_var KUBE_CONTEXT "Kube context to use"
}

# ---------------------------------------------------------------------------
# PMM pod discovery
#
# Tries label selectors in priority order, then falls back to matching any
# pod whose name contains "pmm". Returns "<namespace> <podname>" or empty.
# Pass a namespace to scope the search, or omit for --all-namespaces.
# ---------------------------------------------------------------------------
PMM_POD=""  # set by find_pmm_pod, reused by verify_pmm_running

find_pmm_pod() {
  local ns="${1:-}"
  local -a selectors=(
    "app=pmm-server"
    "app.kubernetes.io/name=pmm-server"
    "app.kubernetes.io/name=pmm"
    "app.kubernetes.io/instance=pmm"
    "app=pmm"
  )

  local ns_flags=("--all-namespaces")
  [[ -n "$ns" ]] && ns_flags=("-n" "$ns")

  local sel result
  for sel in "${selectors[@]}"; do
    result=$(kubectl get pods "${ns_flags[@]}" --context "${KUBE_CONTEXT}" \
      -l "$sel" \
      -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' \
      2>/dev/null || true)
    # jsonpath returns " " (two spaces from empty fields) when no match
    result="${result//  /}"
    result="${result# }"
    [[ -n "$result" ]] && { echo "$result"; return 0; }
  done

  # Fall back: match any pod whose name contains "pmm"
  result=$(kubectl get pods "${ns_flags[@]}" --context "${KUBE_CONTEXT}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -i '\bpmm\b' | head -1 || true)
  [[ -n "$result" ]] && { echo "$result"; return 0; }

  return 1
}

# ---------------------------------------------------------------------------
# PMM namespace resolution
# ---------------------------------------------------------------------------
resolve_namespace() {
  if [[ -n "$PMM_NAMESPACE" ]]; then
    log "PMM_NAMESPACE=$PMM_NAMESPACE"
    return
  fi

  log "Searching for PMM pod across all namespaces..."
  local result
  if result=$(find_pmm_pod) && [[ -n "$result" ]]; then
    PMM_NAMESPACE="${result%% *}"
    PMM_POD="${result##* }"
    log "Auto-detected: namespace='${PMM_NAMESPACE}' pod='${PMM_POD}'"
  else
    warn "Could not auto-detect PMM namespace"
    prompt_var PMM_NAMESPACE "PMM namespace" "pmm"
  fi
}

# ---------------------------------------------------------------------------
# Verify PMM pod is running
# ---------------------------------------------------------------------------
verify_pmm_running() {
  log "Checking PMM pod status in namespace '${PMM_NAMESPACE}'..."

  # Re-use cached pod name if we found it during namespace resolution
  if [[ -z "$PMM_POD" ]]; then
    local result
    result=$(find_pmm_pod "${PMM_NAMESPACE}") || true
    PMM_POD="${result##* }"
  fi

  if [[ -z "$PMM_POD" ]]; then
    # Last resort: list pods so the user can see what's actually there
    warn "Could not locate a PMM pod with any known label or name pattern."
    warn "Pods currently in namespace '${PMM_NAMESPACE}':"
    kubectl get pods -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" \
      -o wide 2>/dev/null >&2 || true
    die "Aborting - set PMM_NAMESPACE and ensure the PMM pod is Running"
  fi

  local phase
  phase=$(kubectl get pod "${PMM_POD}" -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)

  if [[ -z "$phase" ]]; then
    die "Pod '${PMM_POD}' not found in namespace '${PMM_NAMESPACE}'"
  fi
  if [[ "$phase" != "Running" ]]; then
    die "Pod '${PMM_POD}' is in phase '${phase}' - expected Running"
  fi
  log "Pod '${PMM_POD}' is Running"
}

# ---------------------------------------------------------------------------
# Port-forward lifecycle
# ---------------------------------------------------------------------------
PF_PID=""
PF_PORT=""
K3D_TMPKUBE=""

cleanup() {
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    log "Stopping port-forward (pid $PF_PID)..."
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  [[ -n "$K3D_TMPKUBE" ]] && rm -f "$K3D_TMPKUBE"
}
trap cleanup EXIT

find_free_port() {
  local port
  if command -v python3 >/dev/null 2>&1; then
    port=$(python3 -c \
      'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
  else
    # Fall back to scanning a range
    local p
    for p in $(seq 18080 18200); do
      if ! (echo >/dev/tcp/localhost/"$p") 2>/dev/null; then
        port="$p"; break
      fi
    done
    [[ -n "${port:-}" ]] || die "Could not find a free local port in range 18080-18200"
  fi
  echo "$port"
}

start_port_forward() {
  PF_PORT=$(find_free_port)
  log "Starting port-forward: svc/pmm-server:80 -> localhost:${PF_PORT}"
  kubectl port-forward svc/pmm-server "${PF_PORT}:80" \
    -n "${PMM_NAMESPACE}" \
    --context "${KUBE_CONTEXT}" \
    >/dev/null 2>&1 &
  PF_PID=$!

  local i=0
  while [[ "$i" -lt 20 ]]; do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      die "Port-forward process exited unexpectedly - ensure svc/pmm-server exists and port 80 is open"
    fi
    if curl -sf --max-time 2 "http://localhost:${PF_PORT}/v1/readyz" >/dev/null 2>&1; then
      log "PMM reachable on localhost:${PF_PORT}"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  die "PMM did not become reachable on localhost:${PF_PORT} after 20s"
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
extract_ds_uid() {
  local json="$1" uid=""
  case "$JSON_TOOL" in
    jq)
      # .[0] instead of first - first/0 is not reliably defined before jq 1.6
      uid=$(printf '%s' "$json" | jq -r '[.[] | select(.type == "prometheus")] | .[0].uid // empty' 2>/dev/null || true)
      ;;
    python3)
      uid=$(printf '%s' "$json" | python3 -c '
import sys, json
for d in json.load(sys.stdin):
    if d.get("type") == "prometheus":
        print(d.get("uid", ""))
        break
' 2>/dev/null || true)
      ;;
    sed)
      # JSON field order is not guaranteed - try both orderings
      uid=$(printf '%s' "$json" \
        | grep -o '"uid":"[^"]*"[^}]*"type":"prometheus"' \
        | head -1 | sed 's/"uid":"//;s/".*//' || true)
      if [[ -z "$uid" ]]; then
        uid=$(printf '%s' "$json" \
          | grep -o '"type":"prometheus"[^}]*"uid":"[^"]*"' \
          | head -1 | sed 's/.*"uid":"//;s/".*//' || true)
      fi
      ;;
  esac
  printf '%s' "$uid"
}

extract_alert_uid() {
  local json="$1" title="$2" uid=""
  case "$JSON_TOOL" in
    jq)
      uid=$(printf '%s' "$json" \
        | jq -r --arg t "$title" '[.[] | select(.title == $t)] | .[0].uid // empty' 2>/dev/null || true)
      ;;
    python3)
      uid=$(printf '%s' "$json" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r.get('title') == '$title':
        print(r.get('uid', ''))
        break
" 2>/dev/null || true)
      ;;
    sed)
      uid=$(printf '%s' "$json" \
        | grep -o "\"title\":\"${title}\"[^}]*\"uid\":\"[^\"]*\"" \
        | head -1 | sed 's/.*"uid":"//;s/".*//' || true)
      ;;
  esac
  printf '%s' "$uid"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== Grafana MySQL Down Alert Setup ==="

  [[ -f "$ALERT_JSON" ]] || die "Alert JSON template not found: $ALERT_JSON"

  check_deps
  resolve_context
  resolve_namespace
  verify_pmm_running
  prompt_secret PMM_ADMIN_PASSWORD "PMM admin password" "admin"

  start_port_forward

  local base_url="http://localhost:${PF_PORT}/graph"
  local auth="${PMM_ADMIN_PASSWORD:+admin:${PMM_ADMIN_PASSWORD}}"
  local alert_title="MySQL down (Grafana)"

  # --- Fetch datasource UID ---
  log "Fetching Grafana datasources..."
  local ds_json
  if ! ds_json=$(curl -sf -u "$auth" "${base_url}/api/datasources" 2>&1); then
    die "Could not reach Grafana API at ${base_url} - check credentials and PMM health"
  fi

  local ds_uid
  ds_uid=$(extract_ds_uid "$ds_json")
  if [[ -z "$ds_uid" ]]; then
    warn "Could not auto-detect a Prometheus datasource UID from:"
    printf '%s\n' "$ds_json" >&2
    prompt_var ds_uid "Datasource UID to use"
  fi
  log "Datasource UID: $ds_uid"

  # --- Check if alert rule already exists (idempotent) ---
  local method="POST"
  local api_url="${base_url}/api/v1/provisioning/alert-rules"
  local existing_uid=""

  log "Checking for existing alert rule '$alert_title'..."
  local existing_rules
  if existing_rules=$(curl -sf -u "$auth" "$api_url" 2>/dev/null); then
    existing_uid=$(extract_alert_uid "$existing_rules" "$alert_title")
  fi

  if [[ -n "$existing_uid" ]]; then
    log "Alert rule already exists (uid: $existing_uid) - updating in place"
    method="PUT"
    api_url="${api_url}/${existing_uid}"
  else
    log "No existing alert rule found - will create"
  fi

  # --- Build payload ---
  local payload
  payload=$(sed "s/__DATASOURCE_UID__/${ds_uid}/g" "${ALERT_JSON}")

  # PUT requires the uid field in the payload
  if [[ "$method" == "PUT" ]] && [[ -n "$existing_uid" ]]; then
    case "$JSON_TOOL" in
      jq)
        payload=$(printf '%s' "$payload" | jq --arg u "$existing_uid" '. + {uid: $u}')
        ;;
      python3)
        payload=$(printf '%s' "$payload" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['uid'] = '$existing_uid'
print(json.dumps(d))
")
        ;;
      sed)
        # Inject uid before the closing brace - fragile but best effort
        payload=$(printf '%s' "$payload" | sed "s/^{/{\"uid\":\"${existing_uid}\",/")
        ;;
    esac
  fi

  # --- Submit ---
  log "${method}ing alert rule via provisioning API..."
  local resp http_code
  resp=$(curl -s -w '\n%{http_code}' -X "$method" \
    -u "$auth" \
    -H "Content-Type: application/json" \
    -H "X-Disable-Provenance: true" \
    -d "$payload" \
    "$api_url")

  http_code=$(printf '%s' "$resp" | tail -1)
  resp=$(printf '%s' "$resp" | head -n -1)

  if [[ "$http_code" =~ ^2 ]]; then
    log "Success (HTTP $http_code)"
  else
    err "Grafana API returned HTTP $http_code"
    err "Response: $resp"
    die "Alert rule ${method} failed"
  fi

  log "=== Done ==="
}

main "$@"

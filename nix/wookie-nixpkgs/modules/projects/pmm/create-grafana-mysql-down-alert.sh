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
err()  { printf '[ERROR] %s\n' "$*" >&2; }
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
# PMM namespace resolution
# ---------------------------------------------------------------------------
PMM_POD=""

resolve_namespace() {
  if [[ -n "$PMM_NAMESPACE" ]]; then
    log "PMM_NAMESPACE=$PMM_NAMESPACE"
    return
  fi

  log "Searching for PMM pod across all namespaces (by name)..."

  local result ns pod
  result=$(kubectl get pods --all-namespaces --context "${KUBE_CONTEXT}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -i 'pmm' | head -1 || true)
  ns="${result%% *}"
  pod="${result##* }"
  if [[ -n "$ns" && -n "$pod" && "$ns" != "$pod" ]]; then
    PMM_NAMESPACE="$ns"
    PMM_POD="$pod"
    log "Auto-detected: namespace='${PMM_NAMESPACE}' pod='${PMM_POD}'"
    return
  fi

  warn "Could not find a pod with 'pmm' in its name across any namespace"
  prompt_var PMM_NAMESPACE "PMM namespace" "pmm"
}

# ---------------------------------------------------------------------------
# Verify PMM is reachable - informational only, never fatal
# The port-forward in start_port_forward() is the real gate.
# ---------------------------------------------------------------------------
verify_pmm_running() {
  log "Pods in namespace '${PMM_NAMESPACE}':"
  kubectl get pods -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" \
    --no-headers 2>/dev/null | sed 's/^/  /' || true
}

# ---------------------------------------------------------------------------
# Port-forward lifecycle
# ---------------------------------------------------------------------------
PF_PID=""
PF_PORT=""
PMM_SERVICE="${PMM_SERVICE:-}"
PMM_SVC_PORT="${PMM_SVC_PORT:-}"
PMM_SCHEME="http"
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

resolve_pmm_service() {
  log "Services in namespace '${PMM_NAMESPACE}':"

  local svc_list
  svc_list=$(kubectl get svc -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.ports[*]}{.port}{","}{end}{"\n"}{end}' \
    2>/dev/null || true)

  if [[ -z "$svc_list" ]]; then
    warn "No services found in namespace '${PMM_NAMESPACE}' (context '${KUBE_CONTEXT}')"
    warn "Check that the namespace and context are correct."
    prompt_var PMM_SERVICE "Service name to port-forward" "pmm-server"
    prompt_var PMM_SVC_PORT "Service port" "80"
    return
  fi

  # Print everything we found so the user can see it
  local line svc ports
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    svc="${line%% *}"
    ports="${line##* }"
    log "  svc/${svc}  ports: ${ports%,}"
  done <<< "$svc_list"

  # Pick first service that has port 80 (prefer HTTP); fall back to 443
  local candidate_80="" candidate_443=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    svc="${line%% *}"
    ports="${line##* }"
    [[ -z "$candidate_80"  && ("$ports" == *,80,*  || "$ports" == 80,*)  ]] && candidate_80="$svc"
    [[ -z "$candidate_443" && ("$ports" == *,443,* || "$ports" == 443,*) ]] && candidate_443="$svc"
  done <<< "$svc_list"

  if [[ -n "$candidate_80" ]]; then
    PMM_SERVICE="$candidate_80"; PMM_SVC_PORT=80
    log "Auto-selected: svc/${PMM_SERVICE}:${PMM_SVC_PORT}"
    return
  fi
  if [[ -n "$candidate_443" ]]; then
    PMM_SERVICE="$candidate_443"; PMM_SVC_PORT=443
    log "Auto-selected: svc/${PMM_SERVICE}:${PMM_SVC_PORT}"
    return
  fi

  warn "No service with port 80 or 443 found. Showing all services above - pick one."
  prompt_var PMM_SERVICE "Service name to port-forward"
  prompt_var PMM_SVC_PORT "Service port" "80"
}

start_port_forward() {
  if [[ -z "$PMM_SERVICE" ]]; then
    resolve_pmm_service
  fi

  local scheme="http"
  [[ "$PMM_SVC_PORT" == "443" ]] && scheme="https"

  PF_PORT=$(find_free_port)

  # Capture port-forward stderr to a temp file so we can show it on failure
  local pf_log
  pf_log=$(mktemp /tmp/pf-log-XXXXXX.txt)

  log "Running: kubectl port-forward svc/${PMM_SERVICE} ${PF_PORT}:${PMM_SVC_PORT} -n ${PMM_NAMESPACE} --context ${KUBE_CONTEXT}"
  kubectl port-forward "svc/${PMM_SERVICE}" "${PF_PORT}:${PMM_SVC_PORT}" \
    -n "${PMM_NAMESPACE}" \
    --context "${KUBE_CONTEXT}" \
    >"$pf_log" 2>&1 &
  PF_PID=$!

  local i=0
  while [[ "$i" -lt 20 ]]; do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      err "Port-forward process exited. Output was:"
      sed 's/^/  /' "$pf_log" >&2 || true
      rm -f "$pf_log"
      err "Namespace : ${PMM_NAMESPACE}"
      err "Context   : ${KUBE_CONTEXT}"
      err "Service   : ${PMM_SERVICE}"
      err "Port      : ${PMM_SVC_PORT}"
      err "Services currently in namespace:"
      kubectl get svc -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" \
        --no-headers 2>/dev/null | sed 's/^/  /' >&2 || true
      die "Port-forward failed - see output above"
    fi
    local readyz_opts=(-sf --max-time 2)
    [[ "$scheme" == "https" ]] && readyz_opts+=(-k)
    if curl "${readyz_opts[@]}" "${scheme}://localhost:${PF_PORT}/v1/readyz" >/dev/null 2>&1; then
      log "PMM reachable on localhost:${PF_PORT} (${scheme})"
      PMM_SCHEME="$scheme"
      rm -f "$pf_log"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  err "Port-forward is running but PMM did not respond on ${scheme}://localhost:${PF_PORT}/v1/readyz after 20s"
  err "Port-forward output so far:"
  sed 's/^/  /' "$pf_log" >&2 || true
  rm -f "$pf_log"
  die "PMM unreachable - check that the PMM pod is healthy"
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

  local curl_opts=(-s)
  [[ "$PMM_SCHEME" == "https" ]] && curl_opts+=(-k)

  local base_url="${PMM_SCHEME}://localhost:${PF_PORT}/graph"
  local auth="${PMM_ADMIN_PASSWORD:+admin:${PMM_ADMIN_PASSWORD}}"
  local alert_title="MySQL down (Grafana)"

  # --- Fetch datasource UID ---
  log "Fetching Grafana datasources..."
  local ds_json
  if ! ds_json=$(curl "${curl_opts[@]}" -f -u "$auth" "${base_url}/api/datasources" 2>&1); then
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
  if existing_rules=$(curl "${curl_opts[@]}" -f -u "$auth" "$api_url" 2>/dev/null); then
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
  resp=$(curl "${curl_opts[@]}" -w '\n%{http_code}' -X "$method" \
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

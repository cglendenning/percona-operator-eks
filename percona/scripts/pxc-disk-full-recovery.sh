#!/usr/bin/env bash
# Recover a Percona XtraDB Cluster (PXC) namespace when data volumes are full or
# pods are in CrashLoopBackOff. WSL-friendly (bash, kubectl, jq). Run with LF
# line endings; avoid CRLF so shebang works in Git Bash/WSL.
#
# - Inspects PVCs, pods, and basic MySQL state on healthy members.
# - Suggests oldest binary logs from SHOW BINARY LOGS and can run PURGE when a
#   writable MySQL instance is reachable via kubectl exec.
# - For CrashLoopBackOff PXC pods, can schedule a privileged debug pod on the
#   same node with the datadir PVC mounted read/write, but only after the PVC
#   is free. For standard StatefulSets with RWO volumes, Kubernetes only
#   releases the highest ordinal cleanly when you temporarily scale that
#   StatefulSet down (and pause the Percona operator so it does not undo you).
#
# Kubeconfig: every kubectl uses --kubeconfig when KUBECONFIG is set (non-empty).
#
# Usage:
#   ./pxc-disk-full-recovery.sh -n NAMESPACE [-c PXC_CR_NAME] [--recovery-image busybox:1.36]
#
# Environment:
#   RECOVERY_BUSYBOX_IMAGE  override busybox image tag (default busybox:1.36)
#
set -euo pipefail

TAB=$'\t'

usage() {
  sed -n '1,30p' "$0" >&2
  exit 1
}

die() {
  echo "[pxc-disk-recovery] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[pxc-disk-recovery] $*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

NAMESPACE=""
PXC_CR=""
RECOVERY_IMAGE="${RECOVERY_BUSYBOX_IMAGE:-busybox:1.36}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    -c|--cluster)
      PXC_CR="${2:-}"
      shift 2
      ;;
    --recovery-image)
      RECOVERY_IMAGE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "unknown option: $1 (use -h)"
      ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die "namespace is required (-n/--namespace)"

need kubectl
need jq

kube() {
  if [[ -n "${KUBECONFIG:-}" ]]; then
    kubectl --kubeconfig="$KUBECONFIG" "$@"
  else
    kubectl "$@"
  fi
}

confirm() {
  local msg="$1"
  local must="$2"
  local line
  printf "%s\nType exactly: %s\n" "$msg" "$must" >&2
  read -r line
  [[ "$line" == "$must" ]]
}

list_pxc_cr_names() {
  kube get pxc -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[]?.metadata.name // empty' \
    | grep -v '^$' || true
}

choose_cluster() {
  local names
  mapfile -t names < <(list_pxc_cr_names)
  [[ "${#names[@]}" -gt 0 ]] || die "no PerconaXtraDBCluster (pxc) resources in namespace $NAMESPACE"
  if [[ -n "$PXC_CR" ]]; then
    local n
    for n in "${names[@]}"; do
      [[ "$n" == "$PXC_CR" ]] && return 0
    done
    die "PXC CR '$PXC_CR' not found in $NAMESPACE (have: ${names[*]})"
  fi
  if [[ "${#names[@]}" -eq 1 ]]; then
    PXC_CR="${names[0]}"
    log "single PXC CR in namespace: $PXC_CR"
    return 0
  fi
  log "multiple PXC clusters in namespace; pick one:"
  local i=0
  for n in "${names[@]}"; do
    echo "  [$i] $n"
    i=$((i + 1))
  done
  printf "Enter number (0-%d): " "$((i - 1))" >&2
  read -r pick
  [[ "$pick" =~ ^[0-9]+$ ]] || die "invalid selection"
  [[ "$pick" -ge 0 && "$pick" -lt "${#names[@]}" ]] || die "out of range"
  PXC_CR="${names[$pick]}"
  log "using PXC CR: $PXC_CR"
}

pod_is_crashloop() {
  local pod="$1"
  kube get pod "$pod" -n "$NAMESPACE" -o json \
    | jq -e '.status.containerStatuses[]?
        | select(.state.waiting.reason == "CrashLoopBackOff")' >/dev/null 2>&1
}

list_pxc_member_pods() {
  kube get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc -o json \
    | jq -r --arg pref "${PXC_CR}-pxc-" '.items[]
        | select(.metadata.name | startswith($pref))
        | .metadata.name'
}

mysql_container_for_pod() {
  local pod="$1"
  local cn
  cn="$(kube get pod "$pod" -n "$NAMESPACE" -o json \
    | jq -r '(.spec.containers[]? | select(.name == "pxc" or .name == "mysql") | .name)
        // .spec.containers[0].name // empty')"
  [[ -n "$cn" ]] || die "cannot resolve mysql container name for pod $pod"
  echo "$cn"
}

datadir_claim_for_pod() {
  local pod="$1"
  local json c volname vn claim
  json="$(kube get pod "$pod" -n "$NAMESPACE" -o json)"
  mapfile -t c < <(jq -r '.spec.containers[].name // empty' <<<"$json")
  volname=""
  for vn in "${c[@]}"; do
    vo="$(jq -r --arg c "$vn" '
      (.spec.containers[] | select(.name == $c) | .volumeMounts[]?
        | select(.mountPath == "/var/lib/mysql") | .name) // empty
    ' <<<"$json")"
    if [[ -n "$vo" ]]; then
      volname="$vo"
      break
    fi
  done
  if [[ -z "$volname" ]]; then
    claim="$(jq -r '
      [.spec.volumes[]? | (.persistentVolumeClaim.claimName // empty)]
        | map(select(length > 0 and (startswith("datadir") or test("datadir"))))
        | first // empty
    ' <<<"$json")"
    echo "$claim"
    return 0
  fi
  jq -r --arg vn "$volname" '
    .spec.volumes[]? | select(.name == $vn) | .persistentVolumeClaim.claimName // empty
  ' <<<"$json"
}

sts_replicas_for_cluster() {
  local sts="${PXC_CR}-pxc"
  kube get sts "$sts" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null \
    || die "StatefulSet '${sts}' not found (unexpected for operator-managed PXC)"
}

ordinal_from_pod() {
  local pod="$1"
  if [[ "$pod" =~ -([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

discover_operator_deployment() {
  local n
  n="$(kube get deploy -n "$NAMESPACE" -l app.kubernetes.io/name=percona-xtradb-cluster-operator \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$n" ]]; then
    echo "$n"
    return 0
  fi
  kube get deploy -n "$NAMESPACE" -o json | jq -r '
    [.items[]
      | select(.metadata.name | test("percona-xtradb-cluster-operator|pxc-operator")) | .metadata.name]
      | unique
      | .[0] // empty'
}

root_password_from_secret() {
  local secret="${PXC_CR}-secrets"
  if ! kube get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1; then
    die "secret ${secret} not found (adjust secret naming outside this script)"
  fi
  kube get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.root}' | base64 -d
}

inspect_cluster() {
  log "Kubernetes resources (PVCs mentioning datadir / cluster prefix)"
  kube get pvc -n "$NAMESPACE" -o wide 2>/dev/null | head -40 || true
  kube get pvc -n "$NAMESPACE" -o json \
    | jq -r --arg p "${PXC_CR}-pxc" '
      .items[]
        | select(.metadata.name | startswith("datadir-\($p)"))
        | "\(.metadata.name)\tphase=\(.status.phase // "?")\trequested=\(.spec.resources.requests.storage // "?")"
    ' \
    | while IFS= read -r line; do
        log "$line"
      done

  log "PXC member pods (${PXC_CR}-pxc-*)"
  local pods
  mapfile -t pods < <(list_pxc_member_pods)
  [[ "${#pods[@]}" -gt 0 ]] || die "no pods named ${PXC_CR}-pxc-* with component=pxc label"

  for p in "${pods[@]}"; do
    printf '%s%s' "- $p" "$TAB"
    kube get pod "$p" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true
    printf '%s' "$TAB"
    if pod_is_crashloop "$p"; then
      echo "CrashLoopBackOff"
    else
      kube get pod "$p" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true
      printf '\n'
    fi
    local claim node
    claim="$(datadir_claim_for_pod "$p" || true)"
    node="$(kube get pod "$p" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    log "    datadir pvc: ${claim:-unknown}  node: ${node:-unknown}"
    if ! pod_is_crashloop "$p"; then
      local ctn
      ctn="$(mysql_container_for_pod "$p")"
      kube exec -n "$NAMESPACE" "$p" -c "$ctn" -- df -h /var/lib/mysql 2>/dev/null \
        || log "    could not exec df on $p"
    fi
  done

  kube get pxc "$PXC_CR" -n "$NAMESPACE" -o yaml 2>/dev/null \
    | head -80 >&2 || true
}

purge_binlogs_via_member() {
  local candidate="$1"
  pod_is_crashloop "$candidate" && die "chosen pod $candidate is CrashLoopBackOff"

  local ctn pw
  ctn="$(mysql_container_for_pod "$candidate")"
  pw="$(root_password_from_secret)"
  export MYSQL_PWD="$pw"

  log "Fetching SHOW BINARY LOGS from pod $candidate (you will be prompted before any PURGE)"

  kube exec -n "$NAMESPACE" "$candidate" -c "$ctn" -- \
    env MYSQL_PWD="$pw" mysql -uroot -N -e "SHOW BINARY LOGS;" \
    || die "unable to reach MySQL inside $candidate"

  log "Suggested cleanup: purge up to EXCLUDING the newest file still needed downstream."
  log "Prefer PURGE BINARY LOGS TO 'filename'; (keeps named file)."
  printf "Enter BINLOG FILENAME for PURGE BINARY LOGS TO (leave empty to skip): " >&2
  read -r target_file
  if [[ -z "$target_file" ]]; then
    log "skipping PURGE."
    unset MYSQL_PWD
    export -n MYSQL_PWD 2>/dev/null || true
    return 0
  fi
  if [[ ! "$target_file" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "unsafe binlog filename (allowed: letters, digits, ._- only): $target_file"
  fi
  confirm \
    "PURGE removes prior binary logs on THIS member (${candidate}). Replica/PITR impact is your responsibility." \
    "PURGE $target_file"
  kube exec -n "$NAMESPACE" "$candidate" -c "$ctn" -- \
    env MYSQL_PWD="$pw" mysql -uroot -e "PURGE BINARY LOGS TO '${target_file}';"
  unset MYSQL_PWD || true
  export -n MYSQL_PWD 2>/dev/null || true
  log "PURGE completed on $candidate (verify space with df)."
}

sanitize_dns_label() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  s="${s##-}"
  s="${s%%-}"
  [[ -n "$s" ]] || s="pxc"
  printf '%s' "$s"
}

recovery_pod_yaml() {
  local name="$1"
  local pvc="$2"
  local node="$3"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    pxc-disk-recovery: "true"
spec:
  nodeName: ${node}
  restartPolicy: Never
  terminationGracePeriodSeconds: 60
  containers:
  - name: recovery
    image: ${RECOVERY_IMAGE}
    command: ["sh", "-c", "sleep 36000"]
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: datadir
      mountPath: /mnt/mysql
  volumes:
  - name: datadir
    persistentVolumeClaim:
      claimName: ${pvc}
EOF
}

wait_operator_scaled_to_zero() {
  local deploy="$1"
  local max=15 i=0 replicas ready
  for ((i = 1; i <= max; i++)); do
    replicas="$(kube get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "x")"
    ready="$(kube get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")"
    if [[ "$replicas" == "0" ]] && { [[ "$ready" == "" ]] || [[ "$ready" == "0" ]]; }; then
      return 0
    fi
    log "waiting for Deployment/${deploy} to scale to zero ($i/${max}); spec=${replicas} ready=${ready:-n/a}"
    sleep 2
  done
  return 1
}

handle_crashloop_member() {
  local pod="$1"
  pod_is_crashloop "$pod" || return 0

  local claim node ord reps sts op
  claim="$(datadir_claim_for_pod "$pod")"
  node="$(kube get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')"
  [[ -n "$claim" ]] || die "cannot resolve datadir PVC for $pod"

  ord="$(ordinal_from_pod "$pod")" || die "cannot parse ordinal from pod name $pod"
  sts="${PXC_CR}-pxc"
  reps="$(sts_replicas_for_cluster)"

  echo ""
  log "CrashLoop pod: $pod"
  log "datadir PVC: $claim  assigned node (last scheduled): ${node:-none}"
  log "StatefulSet replicas: $reps  member ordinal (from pod name): $ord"

  if [[ -z "$node" ]]; then
    die "pod $pod has no spec.nodeName; schedule or investigate before attaching a recovery pod"
  fi

  if [[ "$ord" != "$((reps - 1))" ]]; then
    log "Kubernetes StatefulSet caveat: freeing this PVC without deleting intermediate ordinals normally requires"
    log "scaling the entire ${sts} StatefulSet carefully (risk to Galera quorum). This script will not automate"
    log "PVC takeover for non-highest ordinals."
    printf "Proceed with interactive binlog/other recovery only (already covered). Press Enter.\n" >&2
    read -r
    return 0
  fi

  op="$(discover_operator_deployment)"
  if [[ -z "$op" ]]; then
    die "cannot discover Percona operator Deployment in $NAMESPACE by name heuristic; scale it to 0 manually"
  fi

  printf "\nAutomated PVC recovery for HIGHEST ordinal %s is destructive to this member slot:\n" "$pod" >&2
  printf "  1) scale Deployment/%s replicas -> 0\n" "$op" >&2
  printf "  2) scale StatefulSet/%s replicas %s -> %s (removes ordinal %s)\n" "$sts" "$reps" "$((reps - 1))" "$ord" >&2
  printf "  3) apply a busybox recovery Pod mounting PVC %s on node %s\n" "$claim" "$node" >&2
  printf "\nGalera quorum: ensure you accept losing this member temporarily.\n" >&2

  confirm "If you fully understand quorum impact, proceed with operator/ST scale orchestration." "SCALE-DOWN-${PXC_CR}" \
    || { log "skipped automated recovery orchestration."; return 0; }

  log "scaling operator Deployment/${op} to 0 replicas"
  kube scale deploy/"$op" -n "$NAMESPACE" --replicas=0
  wait_operator_scaled_to_zero "$op" \
    || log "warning: operator Deployment/${op} may still be terminating (verify manually)."

  log "scaling StatefulSet/${sts} $reps -> $((reps - 1))"
  kube scale sts/"$sts" -n "$NAMESPACE" --replicas=$((reps - 1))

  local wait_del=0
  while kube get pod "$pod" -n "$NAMESPACE" >/dev/null 2>&1 && [[ "$wait_del" -lt 15 ]]; do
    sleep 2
    wait_del=$((wait_del + 1))
    log "waiting for pod $pod to disappear ($wait_del)..."
  done
  kube get pod "$pod" -n "$NAMESPACE" >/dev/null 2>&1 && die "pod $pod still exists after STS scale-down"

  local rpod safecr
  safecr="$(sanitize_dns_label "$PXC_CR")"
  rpod="pxc-pvc-recovery-${safecr}-pxc-${ord}-$(date +%s)"
  if [[ "${#rpod}" -gt 200 ]]; then
    rpod="pxc-pvc-recovery-$(printf '%s/%s/%s' "$NAMESPACE" "$PXC_CR" "$ord" | sha256sum | awk '{print substr($1,1,24)}')"
  fi
  recovery_pod_yaml "$rpod" "$claim" "$node" \
    | kube apply -f -
  log "recovery pod ${rpod}"
  printf "inspect: kubectl --kubeconfig=... exec -n %s %s -c recovery -- df -h /mnt/mysql\n" \
    "$NAMESPACE" "$rpod" >&2
  printf "browse binlogs (example): kubectl --kubeconfig=... exec -n %s %s -c recovery -- ls -la /mnt/mysql\n" \
    "$NAMESPACE" "$rpod" >&2

  printf "\nWhen finished freeing space:\n" >&2
  printf "  kubectl --kubeconfig=\"\$KUBECONFIG\" delete pod %s -n %s --wait=false\n" "$rpod" "$NAMESPACE" >&2
  printf "Then restore desired member count:\n" >&2
  printf "  kubectl --kubeconfig=\"\$KUBECONFIG\" scale sts/%s -n %s --replicas=%s\n" "$sts" "$NAMESPACE" "$reps" >&2
  printf "  kubectl --kubeconfig=\"\$KUBECONFIG\" scale deploy/%s -n %s --replicas=1\n" "$op" "$NAMESPACE" >&2
}

main() {
  kube get ns "$NAMESPACE" >/dev/null || die "namespace ${NAMESPACE} not found"

  choose_cluster

  inspect_cluster

  echo ""
  log "Healthy member for MySQL-assisted recovery (shows Running, non-crashloop):"
  local pods running=()
  mapfile -t pods < <(list_pxc_member_pods)
  local p ctn
  for p in "${pods[@]}"; do
    if ! pod_is_crashloop "$p" && kube get pod "$p" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Running; then
      running+=("$p")
      echo "  - $p"
    fi
  done

  if [[ "${#running[@]}" -gt 0 ]]; then
    printf "Enter pod name to use for SHOW BINARY LOGS / PURGE (empty = skip): " >&2
    read -r pick_pod
    if [[ -n "$pick_pod" ]]; then
      purge_binlogs_via_member "$pick_pod"
    fi
  else
    log "no Running PXC pods; binary-log PURGE requires bringing at least one member up or freeing disk first."
  fi

  for p in "${pods[@]}"; do
    pod_is_crashloop "$p" && handle_crashloop_member "$p"
  done

  echo ""
  log "done."
}

main "$@"

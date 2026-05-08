#!/usr/bin/env bash
# Recover a Percona XtraDB Cluster (PXC) namespace when data volumes are full or
# pods are in CrashLoopBackOff. WSL-friendly (bash, kubectl, jq). Run with LF
# line endings; avoid CRLF so shebang works in Git Bash/WSL.
#
# - Inspects PVCs, pods, and disk/binlog layout on every healthy (Running, non-CrashLoop) member.
# - Probes mysqld once per member (TCP + pod IP + sockets). On each reachable member: SHOW BINARY LOGS;
#   optional PURGE BINARY LOGS TO with the same filename on all of them.
# - If SQL is dead everywhere: still reports disk, then optional filesystem binlog deletion + *.index prune
#   on all healthy members (strong warnings if mysqld is still running).
# - After healthy members: CrashLoopBackOff datadir PVCs get a busybox recovery Pod (when this script can
#   release the volume) with the same optional filesystem binlog cleanup at /mnt/mysql; you can also name
#   extra recovery Pods to treat other detached PVC mounts the same way.
# - For CrashLoopBackOff PXC pods, can schedule a privileged debug pod on the
#   same node with the datadir PVC mounted read/write, but only after the PVC
#   is free. For standard StatefulSets with RWO volumes, Kubernetes only
#   releases the highest ordinal cleanly when you temporarily scale that
#   StatefulSet down (and pause the Percona operator so it does not undo you).
#
# Kubeconfig: every kubectl uses --kubeconfig when KUBECONFIG is set (non-empty).
#
# Usage:
#   ./pxc-disk-full-recovery.sh -n NAMESPACE [-c PXC_CR_NAME] [--root-secret SECRET]
#       [--recovery-image busybox:1.36]
#
# Environment:
#   RECOVERY_BUSYBOX_IMAGE  override busybox image tag (default busybox:1.36)
#   PXC_ROOT_SECRET_NAME    Kubernetes Secret containing MySQL root password (key: root).
#                           Overrides default name ${PXC_CR}-secrets; --root-secret wins if both set.
#   PXC_MYSQL_HOST          primary TCP target for mysql client (default 127.0.0.1)
#   PXC_MYSQL_PORT          mysqld port (default 3306)
#   PXC_MYSQL_WARMUP_SECONDS optional sleep once before probing all members (default 0)
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
ROOT_SECRET_NAME="${PXC_ROOT_SECRET_NAME:-}"

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
    --root-secret)
      ROOT_SECRET_NAME="${2:-}"
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

# MySQL client inside PXC pods: try TCP then Unix sockets (single probe pass per pod; no retry storms).
PXC_MYSQL_HOST="${PXC_MYSQL_HOST:-127.0.0.1}"
PXC_MYSQL_PORT="${PXC_MYSQL_PORT:-3306}"
PXC_MYSQL_WARMUP_SECONDS="${PXC_MYSQL_WARMUP_SECONDS:-0}"
# Hard caps for kubectl exec probes (super aggressive by default).
PXC_KUBECTL_EXEC_TIMEOUT_SECS="${PXC_KUBECTL_EXEC_TIMEOUT_SECS:-3}"
PXC_MYSQL_PROBE_TIMEOUT_SECS="${PXC_MYSQL_PROBE_TIMEOUT_SECS:-3}"

LAST_MYSQL_CTN=""
# Parallel arrays populated by probe_mysql_on_healthy_members: pod name -> working container name
MYSQL_REACHABLE_PODS=()
MYSQL_REACHABLE_CTNS=()

# Last successful healthy-member filesystem basename list (base64 of newline-separated names), reused for mounts.
LAST_FS_BINLOG_B64=""
need kubectl
need jq

KUBECTL=(kubectl)
if [[ -n "${KUBECONFIG:-}" ]]; then
  KUBECTL+=(--kubeconfig="$KUBECONFIG")
fi

kube() {
  "${KUBECTL[@]}" "$@"
}

run_with_timeout() {
  local secs="$1"
  shift
  if [[ ! "${secs}" =~ ^[0-9]+$ ]] || [[ "${secs}" -lt 1 ]]; then
    die "bad timeout seconds: ${secs}"
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
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 124
    fi
    sleep 1
    i=$((i + 1))
  done
  wait "${pid}"
}

confirm() {
  local msg="$1"
  local must="$2"
  local line
  printf "%s\nType exactly: %s\n" "$msg" "$must" >&2
  read -r line
  [[ "$line" == "$must" ]]
}

confirm_ci() {
  local msg="$1"
  local must_lower="$2"
  local line
  printf "%s\nType exactly: %s\n" "$msg" "$must_lower" >&2
  read -r line
  line="${line,,}"
  [[ "$line" == "$must_lower" ]]
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

# Prefer containers that mount /var/lib/mysql (where mysqld runs); fall back to mysql_container_for_pod.
mysql_containers_to_try() {
  local pod="$1"
  local json
  json="$(kube get pod "$pod" -n "$NAMESPACE" -o json)"
  local -a names=()
  mapfile -t names < <(jq -r '
    [.spec.containers[]
      | select(any(.volumeMounts[]?; .mountPath == "/var/lib/mysql"))
      | .name]
      | unique[]
  ' <<<"$json")
  if [[ "${#names[@]}" -gt 0 && -n "${names[0]}" ]]; then
    printf '%s\n' "${names[@]}"
    return 0
  fi
  mysql_container_for_pod "$pod"
}

_pod_primary_ip() {
  local pod="$1" ctn="$2"
  run_with_timeout "${PXC_KUBECTL_EXEC_TIMEOUT_SECS}" "${KUBECTL[@]}" exec -n "$NAMESPACE" "$pod" -c "$ctn" -- \
    sh -c 'hostname -i 2>/dev/null || true' 2>/dev/null | awk '{ print $1 }'
}

list_healthy_member_pods() {
  local pods p
  mapfile -t pods < <(list_pxc_member_pods)
  for p in "${pods[@]}"; do
    pod_is_crashloop "$p" && continue
    kube get pod "$p" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Running || continue
    echo "$p"
  done
}

log_member_coarse_k8s_state() {
  local p="$1" phase ready_reason
  phase="$(kube get pod "$p" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")"
  ready_reason="$(kube get pod "$p" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '[.status.conditions[]? | select(.type=="Ready") | "\(.status) (\(.reason // .type))"] | join(" ")')"
  [[ -z "$ready_reason" ]] || ready_reason=" Ready:${ready_reason}"
  log "${p}${ready_reason:-} phase=${phase}"
}

primary_datadir_container() {
  local pod="$1"
  local _ctdf=()
  mapfile -t _ctdf < <(mysql_containers_to_try "$pod")
  if [[ "${#_ctdf[@]}" -gt 0 && -n "${_ctdf[0]}" ]]; then
    echo "${_ctdf[0]}"
    return 0
  fi
  mysql_container_for_pod "$pod"
}

disk_snapshot_on_mount() {
  local pod="$1" ctn="$2" dd="$3"
  local show_mysqld="${4:-1}"
  log "--- disk / binlogs: ${pod} container=${ctn} mount=${dd} ---"
  if ! kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- df -h "$dd" 2>/dev/null; then
    if ! kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- df "$dd" 2>/dev/null; then
      log "    df failed (exec error). diagnostics:"
      kube get pod "$pod" -n "$NAMESPACE" -o wide 2>/dev/null || true
      kube get pod "$pod" -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r '.status.containerStatuses[]? | "\(.name)\tready=\(.ready)\trestart=\(.restartCount)\tstate=\(.state|keys[0])\treason=\(.state.waiting.reason // \"-\")"' \
        2>/dev/null || true
      kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- sh -c 'id; uname -a; command -v df || true; ls -la / 2>/dev/null | head -20' 2>/dev/null || true
    fi
  fi
  if [[ "$show_mysqld" == "1" ]]; then
    kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- \
      sh -c 'echo "mysqld process:"; (command -v pgrep >/dev/null 2>&1 && pgrep -a mysqld) || ps aux | awk "/[m]ysqld/ {print}"' \
      2>/dev/null || true
  fi
  kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- env SNAP_DD="$dd" sh -ec '
    dd="$SNAP_DD"
    cd "$dd" 2>/dev/null && ls -lhS . 2>/dev/null | head -30
  ' 2>/dev/null || true
  kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- env SNAP_DD="$dd" sh -ec '
    dd="$SNAP_DD"
    # Unique, stable listing of binlog-like files (avoid double-globbing / double-printing).
    paths="$(ls -1 "$dd"/binlog.* "$dd"/*-bin.* "$dd"/*.index 2>/dev/null | sort -u || true)"
    [ -z "${paths}" ] && exit 0
    # Print sizes; sort by size desc (best-effort: relies on ls -lh format).
    for p in $paths; do
      [ -f "$p" ] && ls -lh "$p" 2>/dev/null
    done | sort -k5 -h -r | head -40
  ' 2>/dev/null || true
}

disk_snapshot_on_member() {
  disk_snapshot_on_mount "$1" "$2" /var/lib/mysql 1
}

# Streams SQL on stdin to mysql. Tries: TCP configured host, TCP pod IP, Unix sockets.
mysql_query_once() {
  local pod="$1" ctn="$2" pw="$3" use_n="$4" sql="$5" show_err="$6"
  local -a base=()
  [[ "$use_n" == "y" ]] && base+=(-N)
  local err_sink=/dev/null
  [[ "$show_err" == "1" ]] && err_sink=/dev/stderr
  local hip sock

  hip="$(_pod_primary_ip "$pod" "$ctn")"

  if printf '%s\n' "$sql" | run_with_timeout "${PXC_MYSQL_PROBE_TIMEOUT_SECS}" "${KUBECTL[@]}" exec -i -n "$NAMESPACE" "$pod" -c "$ctn" -- \
      env MYSQL_PWD="$pw" mysql "${base[@]}" \
        --protocol=TCP -h"$PXC_MYSQL_HOST" -P"$PXC_MYSQL_PORT" -uroot 2>"$err_sink"; then
    return 0
  fi
  if [[ -n "$hip" ]] && printf '%s\n' "$sql" | run_with_timeout "${PXC_MYSQL_PROBE_TIMEOUT_SECS}" "${KUBECTL[@]}" exec -i -n "$NAMESPACE" "$pod" -c "$ctn" -- \
      env MYSQL_PWD="$pw" mysql "${base[@]}" \
        --protocol=TCP -h"$hip" -P"$PXC_MYSQL_PORT" -uroot 2>"$err_sink"; then
    return 0
  fi
  for sock in /var/lib/mysql/mysql.sock /var/run/mysqld/mysqld.sock /tmp/mysql.sock; do
    run_with_timeout "${PXC_MYSQL_PROBE_TIMEOUT_SECS}" "${KUBECTL[@]}" exec -n "$NAMESPACE" "$pod" -c "$ctn" -- test -S "$sock" 2>/dev/null || continue
    if printf '%s\n' "$sql" | run_with_timeout "${PXC_MYSQL_PROBE_TIMEOUT_SECS}" "${KUBECTL[@]}" exec -i -n "$NAMESPACE" "$pod" -c "$ctn" -- \
        env MYSQL_PWD="$pw" mysql "${base[@]}" --socket="$sock" -uroot 2>"$err_sink"; then
      return 0
    fi
  done
  return 1
}

mysql_probe_pod() {
  local pod="$1" pw="$2"
  local -a ctns=()
  mapfile -t ctns < <(mysql_containers_to_try "$pod")
  [[ "${#ctns[@]}" -gt 0 ]] || return 1
  local c
  for c in "${ctns[@]}"; do
    if mysql_query_once "$pod" "$c" "$pw" y "SELECT 1;" 0; then
      LAST_MYSQL_CTN="$c"
      return 0
    fi
  done
  return 1
}

probe_mysql_on_healthy_members() {
  local pw="$1"
  shift
  local -a healthy=("$@")
  MYSQL_REACHABLE_PODS=()
  MYSQL_REACHABLE_CTNS=()
  [[ "${#healthy[@]}" -gt 0 ]] || return 1
  local p
  for p in "${healthy[@]}"; do
    LAST_MYSQL_CTN=""
    if mysql_probe_pod "$p" "$pw"; then
      MYSQL_REACHABLE_PODS+=("$p")
      MYSQL_REACHABLE_CTNS+=("${LAST_MYSQL_CTN}")
      log "mysqld accepts SQL on ${p} container=${LAST_MYSQL_CTN}"
    else
      log "mysql probe failed on ${p} (single-pass, ${PXC_MYSQL_PROBE_TIMEOUT_SECS}s cap per exec)"
    fi
  done
  [[ "${#MYSQL_REACHABLE_PODS[@]}" -gt 0 ]]
}

show_binary_logs_every_reachable() {
  local pw="$1"
  local i p c
  for i in "${!MYSQL_REACHABLE_PODS[@]}"; do
    p="${MYSQL_REACHABLE_PODS[$i]}"
    c="${MYSQL_REACHABLE_CTNS[$i]}"
    printf '\n===== SHOW BINARY LOGS: %s (container=%s) =====\n' "$p" "$c" >&2
    mysql_query_once "$p" "$c" "$pw" y "SHOW BINARY LOGS;" 1 || log "WARN: SHOW BINARY LOGS failed on $p"
  done
}

purge_binary_logs_every_reachable() {
  local pw="$1" target_file="$2"
  local i p c fails=0
  for i in "${!MYSQL_REACHABLE_PODS[@]}"; do
    p="${MYSQL_REACHABLE_PODS[$i]}"
    c="${MYSQL_REACHABLE_CTNS[$i]}"
    printf '\n===== PURGING on %s (container=%s) =====\n' "$p" "$c" >&2
    mysql_query_once "$p" "$c" "$pw" n "PURGE BINARY LOGS TO '${target_file}';" 1 \
      || { log "WARN: PURGE failed on ${p}"; fails=$((fails + 1)); }
  done
  [[ "$fails" -eq 0 ]] || log "${fails} member(s) failed PURGE; verify each instance."
}

mysqld_process_running_exec() {
  local pod="$1" ctn="$2"
  kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- \
    sh -c '(command -v pgrep >/dev/null 2>&1 && pgrep mysqld >/dev/null 2>&1) || ps aux | grep -q "[m]ysqld"' \
    2>/dev/null
}

wait_pod_phase_running() {
  local pod="$1"
  local max="${2:-24}"
  local i phase
  for ((i = 1; i <= max; i++)); do
    phase="$(kube get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" ]]; then
      return 0
    fi
    log "waiting for pod ${pod} phase=Running (now: ${phase:-missing}) ${i}/${max}"
    sleep 2
  done
  return 1
}

wait_pod_container_running() {
  local pod="$1"
  local ctn="$2"
  local max="${3:-24}"
  local i state
  for ((i = 1; i <= max; i++)); do
    state="$(
      kube get pod "$pod" -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r --arg c "$ctn" '
            (.status.containerStatuses[]? | select(.name==$c) | (.state | keys[0])) // empty
          '
    )"
    if [[ "$state" == "running" ]]; then
      return 0
    fi
    log "waiting for pod ${pod} container ${ctn} state=running (now: ${state:-missing}) ${i}/${max}"
    sleep 2
  done
  return 1
}

pack_basenames_line_to_b64() {
  local base_line="$1"
  local -a bases=()
  read -r -a bases <<<"$base_line"
  local tok baselist_packed=""
  for tok in "${bases[@]}"; do
    [[ -z "$tok" ]] && continue
    if [[ ! "$tok" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
      die "unsafe basename rejected: ${tok}"
    fi
    baselist_packed+="${tok}"$'\n'
  done
  [[ -n "$baselist_packed" ]] || die "no valid basenames"
  printf '%s' "$baselist_packed" | base64 | tr -d '\n'
}

list_binlog_basenames_on_mount() {
  local pod="$1" ctn="$2" dd="$3"
  echo "" >&2
  log "Binlog-like files on ${pod}:${dd} (basenames):"
  kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -- env SNAP_DD="$dd" sh -ec '
    dd="$SNAP_DD"
    cd "$dd" 2>/dev/null || exit 0
    # BusyBox find often lacks -printf; use globbing + ls and strip paths.
    (
      ls -1 "$dd"/binlog.* "$dd"/*-bin.* "$dd"/*.index 2>/dev/null \
        | awk -F/ "{print \\$NF}" \
        | sort -u
    ) || true
  ' 2>/dev/null || true
}

# Same binlog file + *.index prune as healthy members, on a recovery Pod mount (default /mnt/mysql).
recovery_mount_filesystem_offer() {
  local rpod="$1"
  local dd="${2:-/mnt/mysql}"
  local ctn="${3:-recovery}"
  local b64="" mode do_fs base_line

  echo ""
  log "PVC recovery pod ${rpod} — datadir mount ${dd} (container ${ctn})"
  disk_snapshot_on_mount "$rpod" "$ctn" "$dd" 0
  list_binlog_basenames_on_mount "$rpod" "$ctn" "$dd"

  b64=""
  if [[ -n "${LAST_FS_BINLOG_B64:-}" ]]; then
    printf "Reuse the same basename list as the healthy-member filesystem cleanup on this mount? (yes/no): " >&2
    read -r mode
    mode="${mode,,}"
    if [[ "$mode" == "yes" || "$mode" == "y" ]]; then
      b64="$LAST_FS_BINLOG_B64"
    fi
  fi

  if [[ -z "$b64" ]]; then
    printf "Run filesystem binlog cleanup on %s in %s? (yes/no): " "$dd" "$rpod" >&2
    read -r do_fs
    do_fs="${do_fs,,}"
    if [[ "$do_fs" != "yes" && "$do_fs" != "y" ]]; then
      log "Skipping filesystem cleanup on recovery mount ${rpod}."
      return 0
    fi
    printf "Space-separated basenames under %s (empty = abort): " "$dd" >&2
    read -r base_line
    if [[ -z "$base_line" ]]; then
      log "No basenames; skipping recovery mount cleanup."
      return 0
    fi
    b64="$(pack_basenames_line_to_b64 "$base_line")"
  fi

  confirm_ci "Delete named binlog files + prune *.index under ${dd} on Pod ${rpod}." \
    "delete" \
    || { log "Aborted recovery mount cleanup."; return 0; }

  if filesystem_binlog_delete_on_pod "$rpod" "$ctn" "$b64" "$dd"; then
    log "filesystem cleanup OK on recovery pod ${rpod}"
  else
    log "WARN: filesystem cleanup failed on ${rpod}"
  fi
  echo ""
  log "Disk after cleanup on ${rpod}:"
  disk_snapshot_on_mount "$rpod" "$ctn" "$dd" 0
}

list_crashloop_member_pods() {
  local pods p
  mapfile -t pods < <(list_pxc_member_pods)
  for p in "${pods[@]}"; do
    pod_is_crashloop "$p" && echo "$p"
  done
}

# Highest ordinal first: matches StatefulSet scale-down order (drop replicas-1, then …).
list_crashloop_member_pods_sorted_by_ordinal_desc() {
  local pods p o
  mapfile -t pods < <(list_pxc_member_pods)
  for p in "${pods[@]}"; do
    pod_is_crashloop "$p" || continue
    o="$(ordinal_from_pod "$p")" || continue
    printf '%04d\t%s\n' "$o" "$p"
  done | sort -t "$(printf '\t')" -k1 -nr | cut -f2
}

filesystem_binlog_delete_on_pod() {
  local pod="$1" ctn="$2" baselist_b64="$3"
  local dd="${4:-/var/lib/mysql}"
  kube exec -n "$NAMESPACE" "$pod" -c "$ctn" -i -- \
    env BINLOG_RM_B64="$baselist_b64" PXC_DATADIR_ROOT="$dd" sh -s <<'EOSCRIPT'
set -eu
datadir="$PXC_DATADIR_ROOT"
cd "$datadir" || exit 2
BN="/tmp/bnames.$$"
IX="/tmp/idxlst.$$"
trap 'rm -f "$BN" "$IX"' EXIT INT HUP
printf '%s' "$BINLOG_RM_B64" | base64 -d >"$BN" || exit 3
while IFS= read -r b; do
  b=$(printf '%s' "$b" | tr -d '\r')
  [ -z "$b" ] && continue
  bn=$(basename "$b")
  case "$bn" in *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-]*)
    echo "reject unsafe basename: $bn" >&2
    exit 2
  ;; esac
  rm -f "$datadir/$bn"
done <"$BN"
find "$datadir" -maxdepth 1 -type f -name '*.index' >"$IX" 2>/dev/null || true
while IFS= read -r idx; do
  [ -z "$idx" ] && continue
  [ ! -f "$idx" ] && continue
  tmp="${idx}.pxc.$$"
  : >"$tmp"
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [ -z "$line" ] && continue
    bnx=$(basename "$line")
    if [ -f "$datadir/$bnx" ]; then
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$idx"
  mv -f "$tmp" "$idx"
done <"$IX"
printf 'filesystem binlog cleanup + index prune done (%s)\n' "$datadir"
EOSCRIPT
}

recovery_flow_disk_mysql_and_maybe_fs() {
  local -a healthy=()
  mapfile -t healthy < <(list_healthy_member_pods)

  echo ""
  log "Healthy members (phase=Running, not CrashLoop): ${healthy[*]:-"(none)"}"
  if [[ "${#healthy[@]}" -eq 0 ]]; then
    log "No healthy pods to probe for disk/mysql; CrashLoop/recovery PVC path follows."
    return 0
  fi

  local pw
  pw="$(root_password_from_secret)"
  local p
  for p in "${healthy[@]}"; do
    log_member_coarse_k8s_state "$p"
  done

  if [[ "${PXC_MYSQL_WARMUP_SECONDS}" =~ ^[0-9]+$ ]] && [[ "${PXC_MYSQL_WARMUP_SECONDS}" -gt 0 ]]; then
    log "PXC_MYSQL_WARMUP_SECONDS=${PXC_MYSQL_WARMUP_SECONDS}; waiting once before probing all members..."
    sleep "${PXC_MYSQL_WARMUP_SECONDS}"
  fi

  echo ""
  log "Disk usage + datadir listings on every healthy member:"
  local ctn
  for p in "${healthy[@]}"; do
    ctn="$(primary_datadir_container "$p")"
    disk_snapshot_on_member "$p" "$ctn"
  done

  echo ""
  log "Single-pass mysqld probe (TCP + pod IP + sockets) across all healthy members."
  probe_mysql_on_healthy_members "$pw" "${healthy[@]}" \
    || true

  if [[ "${#MYSQL_REACHABLE_PODS[@]}" -gt 0 ]]; then
    show_binary_logs_every_reachable "$pw"
    log "SQL reachable on ${#MYSQL_REACHABLE_PODS[@]} member(s). PURGE BINARY LOGS TO runs on **each** of them with the same filename."
    printf "Enter binlog filename for PURGE BINARY LOGS TO on all reachable members (empty = skip SQL purge): " >&2
    read -r target_file
    if [[ -n "$target_file" ]]; then
      if [[ ! "$target_file" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        log "unsafe binlog filename; skipping SQL purge."
      else
        confirm \
          "PURGE removes prior binary logs on every reachable member above. Replica/PITR impact is your responsibility." \
          "PURGE-ALL-${target_file}" \
          && purge_binary_logs_every_reachable "$pw" "$target_file"
      fi
    else
      log "Skipping SQL PURGE."
    fi
  else
    log "mysqld did not accept SQL on any healthy member after one probe pass — cannot use PURGE."
  fi

  echo ""
  log "Optional: delete binlog **files** under /var/lib/mysql on every healthy member and prune *.index lines for missing files."
  log "Unsafe if mysqld is running; only use when instance is wedged / cannot connect. You name basenames (e.g. binlog.000012 mysql-bin.000045)."
  printf "Run filesystem binlog cleanup on all healthy members? (yes/no): " >&2
  read -r do_fs
  do_fs="${do_fs,,}"
  if [[ "$do_fs" != "yes" && "$do_fs" != "y" ]]; then
    log "Skipping filesystem binlog cleanup."
    return 0
  fi

  printf "Space-separated basenames to remove from /var/lib/mysql on ALL healthy members (empty = abort): " >&2
  read -r base_line
  if [[ -z "$base_line" ]]; then
    log "No basenames; abort filesystem cleanup."
    return 0
  fi

  local -a bases=()
  read -r -a bases <<<"$base_line"
  local tok any_mysqld=0
  for tok in "${bases[@]}"; do
    [[ -z "$tok" ]] && continue
    if [[ ! "$tok" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
      die "unsafe basename rejected: ${tok}"
    fi
  done

  local h c
  for h in "${healthy[@]}"; do
    c="$(primary_datadir_container "$h")"
    mysqld_process_running_exec "$h" "$c" && any_mysqld=1
  done
  if [[ "$any_mysqld" -ne 0 ]]; then
    log "mysqld appears to be running on at least one healthy member."
    confirm_ci "Deleting binlog files while mysqld runs can corrupt replication. Confirm you accept that risk." \
      "delete" \
      || { log "Aborted filesystem cleanup."; return 0; }
  else
    confirm_ci "Proceed with filesystem deletes + *.index pruning on all healthy members." \
      "delete" \
      || { log "Aborted filesystem cleanup."; return 0; }
  fi

  local baselist_packed b64
  baselist_packed=""
  for tok in "${bases[@]}"; do
    [[ -z "$tok" ]] && continue
    baselist_packed+="${tok}"$'\n'
  done
  if [[ -z "$baselist_packed" ]]; then
    log "No basenames to apply; abort filesystem cleanup."
    return 0
  fi
  b64="$(printf '%s' "$baselist_packed" | base64 | tr -d '\n')"
  LAST_FS_BINLOG_B64="$b64"

  local ok=0 fail=0
  for h in "${healthy[@]}"; do
    c="$(primary_datadir_container "$h")"
    if filesystem_binlog_delete_on_pod "$h" "$c" "$b64"; then
      log "filesystem cleanup OK on $h"
      ok=$((ok + 1))
    else
      log "WARN: filesystem cleanup failed on $h"
      fail=$((fail + 1))
    fi
  done
  log "filesystem cleanup finished: ok=${ok} failed=${fail}"
  echo ""
  log "Disk after cleanup (all healthy members):"
  for h in "${healthy[@]}"; do
    c="$(primary_datadir_container "$h")"
    disk_snapshot_on_member "$h" "$c"
  done
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
  local secret="${ROOT_SECRET_NAME:-${PXC_CR}-secrets}"
  if ! kube get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1; then
    die "secret '${secret}' not found in ${NAMESPACE} (use --root-secret or PXC_ROOT_SECRET_NAME)"
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
      local ctn _ctdf=()
      mapfile -t _ctdf < <(mysql_containers_to_try "$p")
      ctn="${_ctdf[0]:-}"
      [[ -n "$ctn" ]] || ctn="$(mysql_container_for_pod "$p")"
      kube exec -n "$NAMESPACE" "$p" -c "$ctn" -- df -h /var/lib/mysql 2>/dev/null \
        || log "    could not exec df on $p"
    fi
  done

  kube get pxc "$PXC_CR" -n "$NAMESPACE" -o yaml 2>/dev/null \
    | head -80 >&2 || true
}

sanitize_dns_label() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  s="${s##-}"
  s="${s%%-}"
  [[ -n "$s" ]] || s="pxc"
  printf '%s' "$s"
}

get_pod_scheduling_json() {
  local pod="$1"
  kube get pod "$pod" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq '{nodeSelector, tolerations, affinity, topologySpreadConstraints, priorityClassName, serviceAccountName} | with_entries(select(.value!=null))'
}

pvc_phase() {
  local pvc="$1"
  kube get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

pods_using_pvc() {
  local pvc="$1"
  kube get pods -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg pvc "$pvc" '
      .items[]
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | select(any(.spec.volumes[]?; (.persistentVolumeClaim.claimName // "") == $pvc))
      | .metadata.name
    '
}

wait_pvc_bound_and_unused() {
  local pvc="$1"
  local max="${2:-20}" # ~40s
  local i phase users
  for ((i = 1; i <= max; i++)); do
    phase="$(pvc_phase "$pvc")"
    users="$(pods_using_pvc "$pvc" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [[ -n "$phase" ]] || phase="missing"
    if [[ "$phase" == "Bound" ]] && [[ -z "$users" ]]; then
      return 0
    fi
    log "waiting for PVC ${pvc} phase=Bound and unused (phase=${phase}, users=${users:-none}) ${i}/${max}"
    sleep 2
  done
  return 1
}

recovery_pod_manifest_json() {
  local name="$1"
  local pvc="$2"
  local node="$3"
  local scheduling_json="${4:-{}}"
  jq -n \
    --arg name "$name" \
    --arg ns "$NAMESPACE" \
    --arg node "$node" \
    --arg pvc "$pvc" \
    --arg img "$RECOVERY_IMAGE" \
    --argjson sched "$scheduling_json" \
    '
    {
      apiVersion: "v1",
      kind: "Pod",
      metadata: {
        name: $name,
        namespace: $ns,
        labels: { "pxc-disk-recovery": "true" }
      },
      spec: (
        {
          nodeName: $node,
          restartPolicy: "Never",
          terminationGracePeriodSeconds: 60,
          automountServiceAccountToken: false,
          containers: [
            {
              name: "recovery",
              image: $img,
              imagePullPolicy: "IfNotPresent",
              command: ["sh","-c","sleep 36000"],
              securityContext: { runAsUser: 0 },
              volumeMounts: [{ name: "datadir", mountPath: "/mnt/mysql" }]
            }
          ],
          volumes: [
            { name: "datadir", persistentVolumeClaim: { claimName: $pvc } }
          ]
        }
        + $sched
      )
    }'
}

apply_recovery_pod() {
  local rpod="$1" pvc="$2" node="$3" src_pod="$4"
  local sched
  sched="$(get_pod_scheduling_json "$src_pod" || echo '{}')"
  kube get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1 || die "PVC $pvc not found in $NAMESPACE"
  wait_pvc_bound_and_unused "$pvc" || die "PVC $pvc not ready for attach (still in use or not Bound)"
  recovery_pod_manifest_json "$rpod" "$pvc" "$node" "$sched" | kube apply -f -
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
    log "scaling the entire ${sts} StatefulSet carefully (risk to Galera quorum). Automated recovery Pod apply is skipped."
    local suggest safecr
    safecr="$(sanitize_dns_label "$PXC_CR")"
    suggest="pxc-pvc-recovery-${safecr}-manual-${ord}-$(date +%s)"
    log "When the PVC is unattached from the member Pod, apply a recovery Pod like this (name ${suggest}) and clear space under /mnt/mysql:"
    recovery_pod_manifest_json "$suggest" "$claim" "$node" "$(get_pod_scheduling_json "$pod" || echo '{}')" >&2 || true
    printf "After applying a recovery Pod mounting claim %s, re-run this script namespace/cluster options (it will prompt for extra recovery Pods at the end), or cleanup manually.\n" "$claim" >&2
    printf "Press Enter to continue.\n" >&2
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
  apply_recovery_pod "$rpod" "$claim" "$node" "$pod"
  log "recovery pod ${rpod}"
  printf "inspect: kubectl --kubeconfig=... exec -n %s %s -c recovery -- df -h /mnt/mysql\n" \
    "$NAMESPACE" "$rpod" >&2
  printf "browse binlogs (example): kubectl --kubeconfig=... exec -n %s %s -c recovery -- ls -la /mnt/mysql\n" \
    "$NAMESPACE" "$rpod" >&2

  if wait_pod_phase_running "$rpod"; then
    if wait_pod_container_running "$rpod" recovery; then
      recovery_mount_filesystem_offer "$rpod" /mnt/mysql recovery
      printf "Detach recovery pod %s now (free PVC for PXC to restart)? (yes/no): " "$rpod" >&2
      read -r detach_now
      detach_now="${detach_now,,}"
      if [[ "$detach_now" == "yes" || "$detach_now" == "y" ]]; then
        kube delete pod "$rpod" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
        # don't wait forever; just confirm it started terminating
        sleep 2
        kube get pod "$rpod" -n "$NAMESPACE" >/dev/null 2>&1 || log "recovery pod ${rpod} deleted"

        log "restoring StatefulSet/${sts} replicas -> ${reps}"
        kube scale sts/"$sts" -n "$NAMESPACE" --replicas="$reps"
        log "restoring operator Deployment/${op} replicas -> 1"
        kube scale deploy/"$op" -n "$NAMESPACE" --replicas=1

        # Bounded readiness check for the member ordinal we removed
        local m="${PXC_CR}-pxc-${ord}"
        local tries=0 ph
        while [[ "$tries" -lt 15 ]]; do
          ph="$(kube get pod "$m" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
          if [[ "$ph" == "Running" ]]; then
            log "member pod ${m} is Running"
            break
          fi
          log "waiting for member pod ${m} to be Running (now: ${ph:-missing}) $((tries+1))/15"
          sleep 2
          tries=$((tries + 1))
        done
      else
        log "leaving recovery pod ${rpod} running; remember to delete it and scale STS/operator back up."
      fi
    else
      log "WARN: recovery pod ${rpod} container 'recovery' not running; filesystem cleanup skipped."
      log "Retry later: kubectl exec -n ${NAMESPACE} -c recovery ${rpod} -- df /mnt/mysql"
    fi
  else
    log "WARN: recovery pod ${rpod} did not reach Running quickly; filesystem cleanup skipped. Delete member Pod contention or CSI attach delay."
    log "Retry manually: kubectl exec -n ${NAMESPACE} -c recovery ${rpod} -- df /mnt/mysql"
  fi

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

  recovery_flow_disk_mysql_and_maybe_fs

  mapfile -t pods < <(list_pxc_member_pods)
  local -a crash_first=()
  mapfile -t crash_first < <(list_crashloop_member_pods_sorted_by_ordinal_desc)
  local p
  for p in "${crash_first[@]}"; do
    handle_crashloop_member "$p"
  done

  local -a still_crashing=()
  mapfile -t still_crashing < <(list_crashloop_member_pods)
  if [[ "${#still_crashing[@]}" -gt 0 ]]; then
    echo ""
    log "Members still CrashLoopBackOff after automation: ${still_crashing[*]}"
    log "If you attached any extra recovery Pods (PVC at /mnt/mysql), name them here for the same filesystem binlog cleanup."
    printf "Space-separated recovery Pod names (empty = skip): " >&2
    read -r extra_rp
    if [[ -n "$extra_rp" ]]; then
      local -a erp=()
      read -r -a erp <<<"$extra_rp"
      local er
      for er in "${erp[@]}"; do
        [[ -z "$er" ]] && continue
        kube get pod "$er" -n "$NAMESPACE" >/dev/null 2>&1 || { log "WARN: pod ${er} not found; skip"; continue; }
        recovery_mount_filesystem_offer "$er" /mnt/mysql recovery
      done
    fi
  fi

  echo ""
  log "done."
}

main "$@"

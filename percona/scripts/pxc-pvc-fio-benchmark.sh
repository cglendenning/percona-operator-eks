#!/usr/bin/env bash
set -euo pipefail

# MySQL 8.4.x InnoDB default page size (bytes). Same as MySQL 8.0 Reference Manual: innodb_page_size default 16384 (16 KiB).
# If your PXC instance was initialized with a non-default page size, compare the fio profile whose --bs matches that size.
readonly MYSQL_INNODB_DEFAULT_PAGE_BYTES="16384"

usage() {
  cat <<'EOF'
Usage: pxc-pvc-fio-benchmark.sh --namespace <ns> --storage-class <sc> [options]

Creates a temporary PVC + Pod in Kubernetes, runs fio profiles against that PVC,
prints benchmark output, and always tears down test resources on exit.

Required:
  --namespace, -n        Kubernetes namespace for test resources
  --storage-class, -s    StorageClass to benchmark (if omitted, script prompts from cluster)

Optional:
  --pvc-size             PVC size request (default: 20Gi)
  --image                Benchmark image (default: alpine:3.20)
  --pod-name             Pod name (default: fio-pxc-sc-test)
  --pvc-name             PVC name (default: fio-pxc-sc-test)
  --runtime              Fio runtime seconds per profile (default: 180)
  --size                 Fio test file size (default: 1G)
  --iodepth              Fio iodepth (default: 32)
  --numjobs              Fio numjobs (default: 4)
  --rw-mix-read          Fio rwmixread percentage (default: 70)
  --node-selector        Node selector key=value (repeatable); not the same as NODE NAME below
  --node NAME            Pin the benchmark Pod to this Node (.metadata.name — same NAME as kubectl get nodes)
  --keep                 Keep resources after completion (default: false)
  --yes, -y              Proceed without prompting (danger; for automation only)
  --help, -h             Show this help

Examples:
  ./percona/scripts/pxc-pvc-fio-benchmark.sh -n pxc -s gp3
  ./percona/scripts/pxc-pvc-fio-benchmark.sh -n pxc -s vsphere-csi --runtime 240 --size 16G
  ./percona/scripts/pxc-pvc-fio-benchmark.sh -n pxc -s vsphere-csi --node my-worker-01

  Note: Labels like rke.cattle.io/machine=<id> are Rancher provisioning IDs — they differ from kubectl get nodes NAME.
        Use --node NAME to match nodes by name; use labels only if your workloads use those keys.
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[pxc-fio] missing required tool: $1" >&2
    exit 1
  }
}

prompt_select() {
  local prompt="$1"
  shift
  local options=("$@")
  local count="${#options[@]}"
  if [[ "$count" -eq 0 ]]; then
    return 1
  fi

  echo "$prompt" >&2
  local i
  for ((i=0; i<count; i++)); do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&2
  done

  local choice=""
  while true; do
    read -r -p "Enter choice [1-${count}]: " choice >&2
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
      printf '%s' "${options[$((choice - 1))]}"
      return 0
    fi
    echo "[pxc-fio] invalid choice: ${choice:-<empty>}" >&2
  done
}

detect_kubectl_bin() {
  if command -v kubectl >/dev/null 2>&1; then
    printf '%s' "kubectl"
    return 0
  fi
  if command -v kubectl.exe >/dev/null 2>&1; then
    printf '%s' "kubectl.exe"
    return 0
  fi
  echo "[pxc-fio] missing required tool: kubectl (or kubectl.exe for WSL)" >&2
  exit 1
}

require_positive_int() {
  local value="$1"
  local name="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
    echo "[pxc-fio] invalid ${name}: ${value}" >&2
    exit 1
  fi
}

# Summarize fio JSON (written in-pod) for PXC/MySQL-oriented reporting. Prefers python3; prints a short fallback if unavailable.
print_pxc_style_summary() {
  local json_4k="$1"
  local json_16k="$2"

  echo ""
  echo "================================================================================"
  echo " PXC / MySQL datadir I/O — concise summary (storage benchmark, not query load)"
  echo "================================================================================"
  echo "InnoDB (MySQL 8.4.x): default @@innodb_page_size = ${MYSQL_INNODB_DEFAULT_PAGE_BYTES} bytes (16 KiB)."
  echo "  • Primary comparison for default PXC/MySQL: fio block size 16k (16384 B) ≈ one InnoDB page per I/O unit (rule of thumb)."
  echo "  • fio 4k profile: extra data point (e.g. smaller device blocks / metadata); not the InnoDB default page size."
  echo "Workload: randrw, rwmixread=${RWMIXREAD}%, direct=1, runtime=${RUNTIME}s per profile, iodepth=${IODEPTH}, numjobs=${NUMJOBS}."
  echo ""

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json_4k" "$json_16k" "${RWMIXREAD}" <<'PY'
import json, sys

def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return json.load(f)

def ns_to_us(x):
    if x is None:
        return None
    try:
        return float(x) / 1000.0
    except (TypeError, ValueError):
        return None

def job_lines(job):
    r = job.get("read") or {}
    w = job.get("write") or {}
    ri = r.get("iops")
    wi = w.get("iops")
    rb = r.get("bw")  # KiB/s
    wb = w.get("bw")
    rlat = (r.get("lat_ns") or {}).get("mean")
    wlat = (w.get("lat_ns") or {}).get("mean")
    return ri, wi, rb, wb, ns_to_us(rlat), ns_to_us(wlat)

def aggregate(data):
    jobs = data.get("jobs") or []
    if not jobs:
        return None
    tr = tw = 0.0
    trb = twb = 0.0
    rls, wls = [], []
    for j in jobs:
        ri, wi, rb, wb, rlu, wlu = job_lines(j)
        if ri is not None:
            tr += float(ri)
        if wi is not None:
            tw += float(wi)
        if rb is not None:
            trb += float(rb)
        if wb is not None:
            twb += float(wb)
        if rlu is not None:
            rls.append(rlu)
        if wlu is not None:
            wls.append(wlu)
    rlat_m = sum(rls) / len(rls) if rls else None
    wlat_m = sum(wls) / len(wls) if wls else None
    return tr, tw, trb, twb, rlat_m, wlat_m

def fmt_block(label, path):
    try:
        data = load(path)
    except OSError as e:
        print(f"  {label}: (could not read JSON: {e})")
        return
    agg = aggregate(data)
    if agg is None:
        print(f"  {label}: (no jobs in JSON)")
        return
    tr, tw, trb, twb, rlu, wlu = agg
    try:
        mix = int(sys.argv[3]) if len(sys.argv) > 3 else 70
    except (ValueError, IndexError):
        mix = 70
    print(f"  {label}:")
    print(f"    mixed randrw (rwmixread {mix}% read): read ~{tr:.0f} IOPS, write ~{tw:.0f} IOPS")
    print(f"    bandwidth (fio): read ~{trb:.1f} KiB/s, write ~{twb:.1f} KiB/s")
    if rlu is not None and wlu is not None:
        print(f"    mean latency (fio job mean): read ~{rlu:.1f} µs, write ~{wlu:.1f} µs")

p4, p16 = sys.argv[1], sys.argv[2]
fmt_block("Profile randrw4k  (bs=4 KiB — not default InnoDB page size)", p4)
print("")
fmt_block("Profile randrw16k (bs=16 KiB — matches default InnoDB 16384 B page size)", p16)
print("")
print("Use the 16k row as the first-order match to default PXC/MySQL 8.4 InnoDB page I/O; validate @@innodb_page_size in your live cluster if unsure.")
PY
  else
    echo "  (Install python3 on this host to print parsed IOPS/latency from fio JSON files in the pod.)"
    echo "  JSON paths: ${json_4k}, ${json_16k}"
  fi
  echo "================================================================================"
  echo ""
}

NAMESPACE=""
STORAGE_CLASS=""
PVC_SIZE="20Gi"
IMAGE="alpine:3.20"
POD_NAME="fio-pxc-sc-test"
PVC_NAME="fio-pxc-sc-test"
RUNTIME="180"
FIO_SIZE="1G"
IODEPTH="32"
NUMJOBS="4"
RWMIXREAD="70"
KEEP_RESOURCES="0"
SKIP_CONFIRM="0"
KUBECTL_BIN=""
KUBECONFIG_PATH="${KUBECONFIG:-}"
NODE_SELECTORS=()
NODE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --storage-class|-s)
      STORAGE_CLASS="${2:-}"
      shift 2
      ;;
    --pvc-size)
      PVC_SIZE="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --pod-name)
      POD_NAME="${2:-}"
      shift 2
      ;;
    --pvc-name)
      PVC_NAME="${2:-}"
      shift 2
      ;;
    --runtime)
      RUNTIME="${2:-}"
      shift 2
      ;;
    --size)
      FIO_SIZE="${2:-}"
      shift 2
      ;;
    --iodepth)
      IODEPTH="${2:-}"
      shift 2
      ;;
    --numjobs)
      NUMJOBS="${2:-}"
      shift 2
      ;;
    --rw-mix-read)
      RWMIXREAD="${2:-}"
      shift 2
      ;;
    --node-selector)
      NODE_SELECTORS+=("${2:-}")
      shift 2
      ;;
    --node)
      NODE_NAME="${2:-}"
      shift 2
      ;;
    --keep)
      KEEP_RESOURCES="1"
      shift
      ;;
    --yes|-y)
      SKIP_CONFIRM="1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[pxc-fio] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "[pxc-fio] --namespace is required" >&2
  exit 2
fi
require_positive_int "$RUNTIME" "runtime"
require_positive_int "$IODEPTH" "iodepth"
require_positive_int "$NUMJOBS" "numjobs"
if [[ ! "$RWMIXREAD" =~ ^[0-9]+$ ]] || [[ "$RWMIXREAD" -lt 0 ]] || [[ "$RWMIXREAD" -gt 100 ]]; then
  echo "[pxc-fio] invalid rw-mix-read: ${RWMIXREAD}; expected 0-100" >&2
  exit 1
fi
for selector in "${NODE_SELECTORS[@]}"; do
  if [[ ! "$selector" =~ ^[A-Za-z0-9]([A-Za-z0-9._/-]*[A-Za-z0-9])?=[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
    echo "[pxc-fio] invalid --node-selector '${selector}', expected key=value" >&2
    exit 1
  fi
done
if [[ -n "$NODE_NAME" ]] && [[ "${#NODE_SELECTORS[@]}" -gt 0 ]]; then
  echo "[pxc-fio] use either --node or --node-selector, not both" >&2
  exit 2
fi

KUBECTL_BIN="$(detect_kubectl_bin)"
if [[ -z "$KUBECONFIG_PATH" ]]; then
  echo "[pxc-fio] KUBECONFIG is required and must point to a kubeconfig file" >&2
  exit 2
fi
kubectl() {
  command "$KUBECTL_BIN" --kubeconfig="$KUBECONFIG_PATH" "$@"
}

escape_yaml_double_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# Pod scheduling: either spec.nodeName (matches kubectl get nodes NAME) or nodeSelector labels.
build_pod_placement_yaml() {
  if [[ -n "$NODE_NAME" ]]; then
    echo "  nodeName: \"$(escape_yaml_double_quote "$NODE_NAME")\""
    return 0
  fi
  if [[ "${#NODE_SELECTORS[@]}" -eq 0 ]]; then
    return 0
  fi
  echo "  nodeSelector:"
  local pair key value
  for pair in "${NODE_SELECTORS[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    echo "    ${key}: \"$(escape_yaml_double_quote "$value")\""
  done
}

filter_label_selector_candidates() {
  awk '
    /^kubernetes\.io\/hostname=/ { next }
    /^kubernetes\.io\/os=/ { next }
    /^kubernetes\.io\/arch=/ { next }
    /^beta\.kubernetes\.io\// { next }
    /^node\.kubernetes\.io\// { next }
    /^topology\.kubernetes\.io\// { next }
    /^node-role\.kubernetes\.io\// { next }
    /^kubelet\.kubernetes\.io\// { next }
    /^storage\.kubernetes\.io\// { next }
    /^kubernetes\.azure\.com\// { next }
    # Rancher / fleet internals — IDs here are not kubectl get nodes NAME
    /^rke\.cattle\.io\// { next }
    /^cattle\.io\/cluster-/ { next }
    /^fleet\.cattle\.io\// { next }
    /^field\.cattle\.io\// { next }
    { print }
  '
}

pick_storage_class_if_missing() {
  if [[ -n "$STORAGE_CLASS" ]]; then
    return 0
  fi

  echo "[pxc-fio] --storage-class not provided; querying cluster for storage classes..."
  mapfile -t storage_classes < <(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' --request-timeout=30s | sed '/^$/d')
  if [[ "${#storage_classes[@]}" -eq 0 ]]; then
    echo "[pxc-fio] no StorageClass objects found in cluster" >&2
    exit 1
  fi
  STORAGE_CLASS="$(prompt_select "[pxc-fio] choose a storage class:" "${storage_classes[@]}")"
  echo "[pxc-fio] selected storage class: ${STORAGE_CLASS}"
}

pick_node_placement_if_missing() {
  if [[ -n "$NODE_NAME" ]]; then
    return 0
  fi
  if [[ "${#NODE_SELECTORS[@]}" -gt 0 ]]; then
    return 0
  fi

  cat >&2 <<'PLACEMENT_HELP'

[pxc-fio] Node placement — how this differs from kubectl get nodes NAME
  • kubectl get nodes prints NAME = Node .metadata.name (Kubernetes node object name).
  • Labels like rke.cattle.io/machine=<uuid> are Rancher/machine IDs — they identify a machine,
    not necessarily the NODE column string you see. Use NODE NAME pinning when you want a 1:1 match.

PLACEMENT_HELP

  local mode=""
  echo "[pxc-fio] where should the benchmark Pod run?" >&2
  echo "  1) Pin to a NODE by NAME (same names as kubectl get nodes NAME — recommended)" >&2
  echo "  2) Use a label nodeSelector key=value (match your StatefulSet/podTemplate if applicable)" >&2
  echo "  3) No preference — let the scheduler decide" >&2
  while true; do
    read -r -p "[pxc-fio] Enter choice [1-3]: " mode >&2
    mode="$(printf '%s' "$mode" | tr -d '[:space:]')"
    if [[ "$mode" =~ ^[123]$ ]]; then
      break
    fi
    echo "[pxc-fio] invalid choice (expected 1, 2, or 3)" >&2
  done

  case "$mode" in
    3)
      echo "[pxc-fio] no node placement constraint"
      return 0
      ;;
    1)
      echo "[pxc-fio] querying node names..."
      mapfile -t node_names < <(
        kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' --request-timeout=30s | sed '/^$/d' | sort -u
      )
      if [[ "${#node_names[@]}" -eq 0 ]]; then
        echo "[pxc-fio] no Nodes returned from cluster" >&2
        exit 1
      fi
      NODE_NAME="$(prompt_select "[pxc-fio] choose a NODE NAME (kubectl get nodes NAME):" "${node_names[@]}")"
      echo "[pxc-fio] selected node name: ${NODE_NAME}"
      return 0
      ;;
    2)
      echo "[pxc-fio] querying node labels (Rancher internal IDs filtered out of this list)..."
      mapfile -t selector_candidates < <(
        kubectl get nodes --show-labels --no-headers --request-timeout=30s \
          | awk -F'  +' '
            {
              labels = $NF
              n = split(labels, arr, ",")
              for (i = 1; i <= n; i++) {
                if (arr[i] ~ /=/) {
                  print arr[i]
                }
              }
            }
          ' \
          | filter_label_selector_candidates \
          | sed '/^$/d' \
          | sort -u
      )

      if [[ "${#selector_candidates[@]}" -eq 0 ]]; then
        echo "[pxc-fio] no suitable labels remain after filtering; run without nodeSelector or re-run with --node NAME"
        return 0
      fi

      local chosen
      chosen="$(prompt_select "[pxc-fio] choose a label nodeSelector:" "${selector_candidates[@]}")"
      NODE_SELECTORS+=("$chosen")
      echo "[pxc-fio] selected node selector: ${chosen}"
      return 0
      ;;
    *)
      echo "[pxc-fio] internal error: bad mode=${mode}" >&2
      exit 1
      ;;
  esac
}

print_execution_plan() {
  local kubecfg_display="${KUBECONFIG_PATH}"
  [[ -z "$kubecfg_display" ]] && kubecfg_display="(empty)"

  cat >&2 <<PLAN_EOF

================================================================================
 PXc PVC / fio benchmark — ABOUT TO RUN
================================================================================
This script will CONNECT to your cluster and then:

  1) CREATE a PersistentVolumeClaim in namespace "${NAMESPACE}":
       name: ${PVC_NAME}
       storageClassName: ${STORAGE_CLASS}
       requested size: ${PVC_SIZE}

  2) CREATE a Pod in namespace "${NAMESPACE}":
       name: ${POD_NAME}
       image: ${IMAGE}
       mounts that PVC at /data
PLAN_EOF

  if [[ -n "$NODE_NAME" ]]; then
    echo "       nodeName (pin to this NODE — same NAME as kubectl get nodes):" >&2
    echo "         ${NODE_NAME}" >&2
  elif [[ "${#NODE_SELECTORS[@]}" -gt 0 ]]; then
    echo "       nodeSelector:" >&2
    local sel
    for sel in "${NODE_SELECTORS[@]}"; do
      echo "         ${sel}" >&2
    done
  else
    echo "       Placement: (none — scheduler chooses any qualifying node)" >&2
  fi

  cat >&2 <<PLAN_EOF2

  3) INSTALL fio inside the pod (apk) and WRITE a test file on the volume:
       path: /data/fio.test  size: ${FIO_SIZE}

  4) RUN two sequential fio benchmarks (heavy random read/write IO):
       workload: randrw, rwmixread=${RWMIXREAD}% read
       profiles: bs=4k, then bs=16k
       per-job settings: runtime=${RUNTIME}s, iodepth=${IODEPTH}, numjobs=${NUMJOBS}
       (--eta=always --status-interval=10)

  5) CLEAN UP (--keep not set): delete Pod "${POD_NAME}" and PVC "${PVC_NAME}".
       With --keep: leave Pod/PVC in the cluster for inspection.

CLUSTER CONNECTION:
  kubectl: ${KUBECTL_BIN}
  kubeconfig (--kubeconfig): ${kubecfg_display}

WARNINGS:
  • This consumes real storage I/O and may contend with workloads on shared storage.
  • If this namespace or names collide with existing objects, APPLY may update them.
================================================================================
PLAN_EOF2
}

confirm_proceed() {
  if [[ "$SKIP_CONFIRM" == "1" ]]; then
    echo "[pxc-fio] continuing without confirmation (--yes)" >&2
    return 0
  fi
  print_execution_plan

  local answer=""
  read -r -p "[pxc-fio] Type 'yes' to proceed with the steps above (anything else aborts): " answer >&2
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$answer" == "yes" ]]; then
    echo "[pxc-fio] confirmed — proceeding." >&2
    return 0
  fi
  echo "[pxc-fio] aborted (no PVC/Pod created after this point)." >&2
  exit 0
}

cleanup() {
  if [[ "$KEEP_RESOURCES" == "1" ]]; then
    echo "[pxc-fio] keeping resources (--keep enabled): pod/${POD_NAME}, pvc/${PVC_NAME}"
    return 0
  fi

  echo "[pxc-fio] cleanup: deleting pod/${POD_NAME} (non-blocking)"
  kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # bounded wait loop: no single blocking call longer than 30s
  local pod_gone=0
  for i in $(seq 1 10); do
    if ! kubectl -n "$NAMESPACE" get pod "$POD_NAME" --request-timeout=30s >/dev/null 2>&1; then
      pod_gone=1
      break
    fi
    echo "[pxc-fio] cleanup: waiting for pod deletion (${i}/10)"
    sleep 1
  done
  if [[ "$pod_gone" -eq 0 ]]; then
    echo "[pxc-fio] cleanup: pod still present after 10s; forcing delete"
    kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
  fi

  echo "[pxc-fio] cleanup: deleting pvc/${PVC_NAME}"
  kubectl -n "$NAMESPACE" delete pvc "$PVC_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[pxc-fio] verifying namespace exists: ${NAMESPACE}"
kubectl get ns "$NAMESPACE" --request-timeout=30s >/dev/null
pick_storage_class_if_missing
pick_node_placement_if_missing
if [[ -n "$NODE_NAME" ]]; then
  echo "[pxc-fio] verifying Node exists: ${NODE_NAME}"
  kubectl get node "$NODE_NAME" --request-timeout=30s >/dev/null
fi
echo "[pxc-fio] verifying storageclass exists: ${STORAGE_CLASS}"
kubectl get sc "$STORAGE_CLASS" --request-timeout=30s >/dev/null

confirm_proceed

echo "[pxc-fio] creating test pvc + pod in namespace ${NAMESPACE}"
POD_PLACEMENT_YAML="$(build_pod_placement_yaml)"
cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${PVC_SIZE}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
spec:
  restartPolicy: Never
${POD_PLACEMENT_YAML}
  containers:
    - name: fio
      image: ${IMAGE}
      command: ["/bin/sh","-c"]
      args:
        - apk add --no-cache fio >/tmp/apk.log 2>&1 && sleep 36000
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF

echo "[pxc-fio] waiting for pod Ready (up to 120s, 30s slices)"
for slice in 1 2 3 4; do
  if kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=30s >/dev/null 2>&1; then
    echo "[pxc-fio] pod is Ready"
    break
  fi
  if [[ "$slice" -eq 4 ]]; then
    echo "[pxc-fio] pod did not become Ready within 120s" >&2
    kubectl -n "$NAMESPACE" describe pod "$POD_NAME" || true
    exit 1
  fi
  echo "[pxc-fio] pod not ready yet (${slice}/4); checking status..."
  kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o wide --request-timeout=30s || true
done

run_fio() {
  local name="$1"
  local bs="$2"
  local json_path="/data/fio-${name}.json"

  echo "[pxc-fio] running fio profile: ${name} (bs=${bs}, size=${FIO_SIZE}, runtime=${RUNTIME}s)"
  echo "[pxc-fio] progress updates every 10s..."
  kubectl -n "$NAMESPACE" exec "$POD_NAME" -- \
    fio --name="$name" \
      --filename=/data/fio.test \
      --size="$FIO_SIZE" \
      --bs="$bs" \
      --rw=randrw \
      --rwmixread="$RWMIXREAD" \
      --iodepth="$IODEPTH" \
      --numjobs="$NUMJOBS" \
      --ioengine=libaio \
      --direct=1 \
      --runtime="$RUNTIME" \
      --time_based \
      --eta=always \
      --status-interval=10 \
      --group_reporting \
      --output-format=json \
      --output="$json_path"
  echo "[pxc-fio] completed fio profile: ${name}"
}

run_fio "randrw4k" "4k"
run_fio "randrw16k" "16k"

echo "[pxc-fio] completed benchmarks successfully"

readonly FIO_JSON_4K="/data/fio-randrw4k.json"
readonly FIO_JSON_16K="/data/fio-randrw16k.json"

# Pull JSON to host temp files for python summary (avoid requiring python inside the benchmark container).
_summ_4=""
_summ_16=""
_summ_4="$(mktemp "${TMPDIR:-/tmp}/pxc-fio-randrw4k.XXXXXX.json")"
_summ_16="$(mktemp "${TMPDIR:-/tmp}/pxc-fio-randrw16k.XXXXXX.json")"
echo "[pxc-fio] copying fio JSON from pod for summary..."
kubectl -n "$NAMESPACE" cp "${POD_NAME}:${FIO_JSON_4K}" "${_summ_4}"
kubectl -n "$NAMESPACE" cp "${POD_NAME}:${FIO_JSON_16K}" "${_summ_16}"
print_pxc_style_summary "${_summ_4}" "${_summ_16}"
rm -f "${_summ_4}" "${_summ_16}" 2>/dev/null || true

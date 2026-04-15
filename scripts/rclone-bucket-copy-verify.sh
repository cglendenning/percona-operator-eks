#!/usr/bin/env bash
# Copy and verify one bucket between two SeaweedFS clusters using filer HTTP endpoints
# (no S3 gateway). Runs in the target Kubernetes namespace.
#
# Pushback: rclone is not designed for SeaweedFS filer HTTP (:8888-style) endpoints
# ---------------------------------------------------------------------------
# SeaweedFS documents rclone against the S3-compatible API (usually the filer S3 gateway on
# :8333), not the filer file HTTP API. Pointing rclone's `s3` remote at a filer :8888 URL is
# the wrong protocol and will fail in confusing ways ("directory not found", etc.).
# rclone's `http` backend is read-only and aimed at generic web directory listings; it is not
# a supported stand-in for "use filer instead of S3" for read/write bucket sync.
# This script therefore defaults to `weed filer.sync` for filer-to-filer work, and keeps an
# optional `--mode s3` path only for real S3 API endpoints.
#
# Default mode: filer
# - Preflight: GET /status and JSON list under ${BUCKET_FILER_PREFIX}/<bucket>/ on both filers.
# - Sync: `weed filer.sync` between source and target filer peers for a bounded time window
#   (continuous replication; see FILER_SYNC_SECONDS).
# - Verify: in-cluster Python walk of both filer trees; compares relative paths and byte sizes.
#
# Optional mode: s3 (legacy)
# - Uses rclone s3 remotes against SOURCE_ENDPOINT / TARGET_ENDPOINT (SeaweedFS S3 API, :8333).
#
# Usage:
#   ./rclone-bucket-copy-verify.sh [--kubeconfig PATH] [--namespace NS] [--mode filer|s3]
#
# Filer mode environment (optional):
# - SEAWEEDFS_IMAGE       (default: chrislusf/seaweedfs:4.13)
# - VERIFY_IMAGE          (default: python:3.12-alpine)
# - FILER_SYNC_SECONDS    (default: 600) how long to run filer.sync before SIGTERM
# - BUCKET_FILER_PREFIX   (default: /buckets)
# - FILER_A_FILER_PROXY   set to 1 to pass -a.filerProxy
# - FILER_B_FILER_PROXY   set to 1 to pass -b.filerProxy
#
set -euo pipefail

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "missing required command: $c" >&2
    exit 1
  fi
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-false}"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt_text: " current
    echo
  else
    read -r -p "$prompt_text: " current
  fi
  if [[ -z "$current" ]]; then
    echo "$prompt_text is required." >&2
    exit 1
  fi
  printf -v "$var_name" "%s" "$current"
}

normalize_endpoint() {
  local ep="$1"
  if [[ "$ep" =~ ^https?:// ]]; then
    printf "%s" "$ep"
  else
    printf "http://%s" "$ep"
  fi
}

strip_trailing_slash() {
  local s="$1"
  s="${s%/}"
  printf "%s" "$s"
}

filer_peer_from_url() {
  python3 -c 'import sys,urllib.parse
u=sys.argv[1]
if "://" not in u:
  u="http://"+u
p=urllib.parse.urlparse(u)
host=p.hostname
port=p.port
if not host:
  raise SystemExit("could not parse host from filer URL: "+sys.argv[1])
if port is None:
  # Seaweed filer HTTP default when omitted (avoid guessing 80/443).
  port = 8888
print(host+":"+str(port))' "$1"
}

require_cmd kubectl
require_cmd date
require_cmd curl
require_cmd python3

usage() {
  cat <<'EOF'
Usage: rclone-bucket-copy-verify.sh [--kubeconfig /path/to/kubeconfig] [--namespace NS] [--mode filer|s3]

Options:
  --kubeconfig PATH   Use this kubeconfig file for all kubectl calls.
  --namespace NS      Kubernetes namespace (overrides K8S_NAMESPACE env).
  --mode MODE         filer (default): weed filer.sync + filer HTTP verify.
                      s3: rclone only — expects SeaweedFS S3 API URLs (e.g. :8333), not filer :8888.
  -h, --help          Show this help.

Note: rclone is not intended to drive the filer HTTP file API. Use --mode filer for filer LB
URLs, or expose/use the in-cluster S3 gateway for --mode s3.
EOF
}

preflight_filer_http_bucket() {
  local name="$1"
  local base_url="$2"
  local bucket="$3"
  local prefix="$4"

  base_url="$(strip_trailing_slash "$(normalize_endpoint "$base_url")")"

  echo "$LOG_PREFIX preflight: ${name} filer status: ${base_url}/status"
  if ! out="$(curl -fsS --max-time 20 "${base_url}/status" 2>&1)"; then
    echo "$LOG_PREFIX preflight failed: ${name} GET ${base_url}/status" >&2
    echo "$out" >&2
    exit 2
  fi

  local bucket_url="${base_url}${prefix}/${bucket}/"
  echo "$LOG_PREFIX preflight: ${name} bucket listing: ${bucket_url}"
  if ! json="$(curl -fsS --max-time 30 \
    -H "Accept: application/json" \
    "${bucket_url}?pretty=y" 2>&1)"; then
    echo "$LOG_PREFIX preflight failed: ${name} could not list ${bucket_url}" >&2
    echo "$json" >&2
    exit 2
  fi

  if ! printf "%s" "$json" | python3 -c 'import json,sys
bucket=sys.argv[1]
prefix=sys.argv[2]
obj=json.load(sys.stdin)
if not isinstance(obj, dict):
  raise SystemExit(1)
if "Path" not in obj or "Entries" not in obj:
  raise SystemExit(1)
if not isinstance(obj.get("Entries"), list):
  raise SystemExit(1)
path=str(obj.get("Path",""))
want=(prefix.rstrip("/") + "/" + bucket).rstrip("/")
if path.rstrip("/") != want:
  if path.rstrip("/") != want.rstrip("/"):
    raise SystemExit(1)
' "$bucket" "$prefix" >/dev/null; then
    echo "$LOG_PREFIX preflight failed: ${name} bucket JSON listing did not look like a SeaweedFS filer directory response for bucket '$bucket'." >&2
    echo "$json" >&2
    exit 2
  fi
}

preflight_rclone_s3_bucket_list() {
  if [[ "${SKIP_RCLONE_PREFLIGHT:-0}" == "1" ]]; then
    echo "$LOG_PREFIX skipping rclone S3 preflight (SKIP_RCLONE_PREFLIGHT=1)"
    return 0
  fi

  local pf_pod="rclone-preflight-$(date +%s)-$RANDOM"

  echo "$LOG_PREFIX preflight: creating temporary pod ${pf_pod} to validate S3 endpoints with rclone"

  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" run "$pf_pod" \
    --restart=Never \
    --image="$RCLONE_IMAGE" \
    --env="BUCKET_NAME=${BUCKET_NAME}" \
    --env="SOURCE_ENDPOINT=${SOURCE_ENDPOINT}" \
    --env="TARGET_ENDPOINT=${TARGET_ENDPOINT}" \
    --env="SRC_ACCESS_KEY_ID=${SRC_ACCESS_KEY_ID}" \
    --env="SRC_SECRET_ACCESS_KEY=${SRC_SECRET_ACCESS_KEY}" \
    --env="DST_ACCESS_KEY_ID=${DST_ACCESS_KEY_ID}" \
    --env="DST_SECRET_ACCESS_KEY=${DST_SECRET_ACCESS_KEY}" \
    --env="SRC_REGION=${SRC_REGION}" \
    --env="DST_REGION=${DST_REGION}" \
    --command -- /bin/sh -c '
set -eu
rclone version >/dev/null

rclone config create src s3 \
  provider Other \
  env_auth false \
  access_key_id "$SRC_ACCESS_KEY_ID" \
  secret_access_key "$SRC_SECRET_ACCESS_KEY" \
  region "$SRC_REGION" \
  endpoint "$SOURCE_ENDPOINT" \
  force_path_style true >/dev/null

rclone config create dst s3 \
  provider Other \
  env_auth false \
  access_key_id "$DST_ACCESS_KEY_ID" \
  secret_access_key "$DST_SECRET_ACCESS_KEY" \
  region "$DST_REGION" \
  endpoint "$TARGET_ENDPOINT" \
  force_path_style true >/dev/null

rclone lsf "src:${BUCKET_NAME}" --fast-list --max-depth 1 --s3-no-check-bucket >/dev/null
rclone lsf "dst:${BUCKET_NAME}" --fast-list --max-depth 1 --s3-no-check-bucket >/dev/null
'

  local deadline=$((SECONDS + 300))
  local phase="Unknown"
  while [[ $SECONDS -lt $deadline ]]; do
    phase="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$pf_pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
    if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
      break
    fi
    sleep 2
  done

  echo "$LOG_PREFIX preflight pod logs (${pf_pod}):"
  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" logs "$pf_pod" 2>/dev/null || true

  PF_EXIT="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$pf_pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo 1)"

  if [[ "$phase" != "Succeeded" ]]; then
    echo "$LOG_PREFIX preflight failed: temporary pod phase=${phase} exit=${PF_EXIT}" >&2
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" describe pod "$pf_pod" >&2 || true
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" delete pod "$pf_pod" --ignore-not-found >/dev/null 2>&1 || true
    exit 3
  fi

  if [[ "$PF_EXIT" != "0" ]]; then
    echo "$LOG_PREFIX preflight failed: temporary pod exit code ${PF_EXIT} (phase ${phase})" >&2
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" describe pod "$pf_pod" >&2 || true
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" delete pod "$pf_pod" --ignore-not-found >/dev/null 2>&1 || true
    exit 3
  fi

  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" delete pod "$pf_pod" --ignore-not-found >/dev/null 2>&1 || true

  echo "$LOG_PREFIX preflight: rclone validated both S3 endpoints for bucket ${BUCKET_NAME}"
}

wait_pod_terminal() {
  local pod="$1"
  local max_wait="${2:-900}"
  local deadline=$((SECONDS + max_wait))
  local phase="Unknown"
  while [[ $SECONDS -lt $deadline ]]; do
    phase="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
    if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
      break
    fi
    sleep 3
  done
  printf "%s" "$phase"
}

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
K8S_NAMESPACE="${K8S_NAMESPACE:-}"
SYNC_MODE="${SYNC_MODE:-filer}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.68.2}"
SEAWEEDFS_IMAGE="${SEAWEEDFS_IMAGE:-chrislusf/seaweedfs:4.13}"
VERIFY_IMAGE="${VERIFY_IMAGE:-python:3.12-alpine}"
FILER_SYNC_SECONDS="${FILER_SYNC_SECONDS:-600}"
SRC_REGION="${SRC_REGION:-us-east-1}"
DST_REGION="${DST_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      if [[ $# -lt 2 ]]; then
        echo "--kubeconfig requires a path value" >&2
        exit 1
      fi
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    --namespace)
      if [[ $# -lt 2 ]]; then
        echo "--namespace requires a value" >&2
        exit 1
      fi
      K8S_NAMESPACE="$2"
      shift 2
      ;;
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "--mode requires filer or s3" >&2
        exit 1
      fi
      SYNC_MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

KUBECTL=(kubectl)
if [[ -n "$KUBECONFIG_PATH" ]]; then
  if [[ ! -f "$KUBECONFIG_PATH" ]]; then
    echo "kubeconfig file not found: $KUBECONFIG_PATH" >&2
    exit 1
  fi
  KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH")
fi

LOG_PREFIX="[filersync-bucket-verify]"

case "$SYNC_MODE" in
  filer|s3) ;;
  *)
    echo "invalid --mode: $SYNC_MODE (use filer or s3)" >&2
    exit 1
    ;;
esac

prompt_required K8S_NAMESPACE "Target namespace for job pods"
prompt_required BUCKET_NAME "Bucket name"

BUCKET_FILER_PREFIX="${BUCKET_FILER_PREFIX:-/buckets}"
BUCKET_FILER_PREFIX="$(strip_trailing_slash "$BUCKET_FILER_PREFIX")"
SYNC_PATH="${BUCKET_FILER_PREFIX}/${BUCKET_NAME}"

if [[ "$SYNC_MODE" == "filer" ]]; then
  prompt_required SOURCE_FILER_HTTP "Source filer base URL (host:port or http[s]://host:port)"
  prompt_required TARGET_FILER_HTTP "Target filer base URL (host:port or http[s]://host:port)"

  SOURCE_FILER_HTTP="$(strip_trailing_slash "$(normalize_endpoint "$SOURCE_FILER_HTTP")")"
  TARGET_FILER_HTTP="$(strip_trailing_slash "$(normalize_endpoint "$TARGET_FILER_HTTP")")"

  SRC_PEER="$(filer_peer_from_url "$SOURCE_FILER_HTTP")"
  DST_PEER="$(filer_peer_from_url "$TARGET_FILER_HTTP")"

  preflight_filer_http_bucket "source" "$SOURCE_FILER_HTTP" "$BUCKET_NAME" "$BUCKET_FILER_PREFIX"
  preflight_filer_http_bucket "target" "$TARGET_FILER_HTTP" "$BUCKET_NAME" "$BUCKET_FILER_PREFIX"

  SYNC_POD="weed-filersync-$(date +%s)-$RANDOM"
  echo "$LOG_PREFIX namespace: ${K8S_NAMESPACE}"
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    echo "$LOG_PREFIX kubeconfig: ${KUBECONFIG_PATH}"
  fi
  echo "$LOG_PREFIX mode: filer (weed filer.sync)"
  echo "$LOG_PREFIX sync pod: ${SYNC_POD}"
  echo "$LOG_PREFIX bucket path on filers: ${SYNC_PATH}"
  echo "$LOG_PREFIX filer A (-a): ${SRC_PEER} (from ${SOURCE_FILER_HTTP})"
  echo "$LOG_PREFIX filer B (-b): ${DST_PEER} (from ${TARGET_FILER_HTTP})"
  echo "$LOG_PREFIX filer.sync duration: ${FILER_SYNC_SECONDS}s (then SIGTERM; increase FILER_SYNC_SECONDS if needed)"

  cleanup_sync() {
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" delete pod "$SYNC_POD" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap cleanup_sync EXIT

  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" run "$SYNC_POD" \
    --restart=Never \
    --image="$SEAWEEDFS_IMAGE" \
    --env="SRC_PEER=${SRC_PEER}" \
    --env="DST_PEER=${DST_PEER}" \
    --env="SYNC_PATH=${SYNC_PATH}" \
    --env="FILER_SYNC_SECONDS=${FILER_SYNC_SECONDS}" \
    --env="FILER_A_FILER_PROXY=${FILER_A_FILER_PROXY:-0}" \
    --env="FILER_B_FILER_PROXY=${FILER_B_FILER_PROXY:-0}" \
    --command -- /bin/sh -c '
set -eu
echo "[pod] weed version:"
weed version || true

echo "[pod] starting weed filer.sync (background) for ${FILER_SYNC_SECONDS}s"
set -- weed filer.sync \
  -a "${SRC_PEER}" \
  -b "${DST_PEER}" \
  -isActivePassive=true \
  -a.path="${SYNC_PATH}" \
  -b.path="${SYNC_PATH}"

if [ "${FILER_A_FILER_PROXY}" = "1" ]; then
  set -- "$@" -a.filerProxy
fi
if [ "${FILER_B_FILER_PROXY}" = "1" ]; then
  set -- "$@" -b.filerProxy
fi

"$@" &
pid=$!

i=0
while [ "$i" -lt "${FILER_SYNC_SECONDS}" ]; do
  sleep 1
  i=$((i + 1))
done

echo "[pod] sending SIGTERM to filer.sync (pid ${pid})"
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
echo "[pod] filer.sync stopped after ${FILER_SYNC_SECONDS}s window"
exit 0
'

  echo "$LOG_PREFIX waiting for sync pod to finish..."
  sync_phase="$(wait_pod_terminal "$SYNC_POD" $((FILER_SYNC_SECONDS + 120)))"
  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" logs "$SYNC_POD" 2>/dev/null || true
  sync_exit="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$SYNC_POD" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
  sync_exit="${sync_exit:-1}"
  cleanup_sync
  trap - EXIT

  if [[ "$sync_phase" != "Succeeded" ]]; then
    echo "$LOG_PREFIX sync pod phase=${sync_phase} exit=${sync_exit}" >&2
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" describe pod "$SYNC_POD" >&2 || true
    exit 4
  fi

  VERIFY_POD="filer-tree-verify-$(date +%s)-$RANDOM"
  VERIFY_TMP="$(mktemp)"
  trap 'rm -f "$VERIFY_TMP"' EXIT

  cat <<'PY' >"$VERIFY_TMP"
import json
import os
import urllib.error
import urllib.parse
import urllib.request

def http_json(url: str):
    req = urllib.request.Request(
        url,
        headers={"Accept": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read().decode("utf-8"))

def file_size_from_entry(entry: dict) -> int:
    chunks = entry.get("chunks") or []
    if chunks:
        return int(sum(int(c.get("size") or 0) for c in chunks))
    fsz = entry.get("FileSize")
    if fsz is not None:
        return int(fsz)
    return 0

def is_dir_listing(base: str, fullpath: str) -> bool:
    """True if GET /fullpath/ returns a JSON directory listing."""
    url = base.rstrip("/") + fullpath.rstrip("/") + "/?pretty=y&limit=1"
    try:
        doc = http_json(url)
    except urllib.error.HTTPError:
        return False
    return isinstance(doc, dict) and "Entries" in doc

def list_children(base: str, dir_path: str):
    last = ""
    while True:
        q = [("pretty", "y"), ("limit", "2000")]
        if last:
            q.append(("lastFileName", last))
        qs = urllib.parse.urlencode(q)
        url = base.rstrip("/") + dir_path.rstrip("/") + "/?" + qs
        doc = http_json(url)
        entries = doc.get("Entries") or []
        for ent in entries:
            fp = ent.get("FullPath")
            if fp:
                yield fp, ent
        if not doc.get("ShouldDisplayLoadMore"):
            break
        if not entries:
            break
        last = entries[-1].get("FullPath", "").rsplit("/", 1)[-1]
        if not last:
            break

def walk_files(base: str, root_dir: str):
    out = {}
    root_dir = root_dir.rstrip("/")
    stack = [root_dir + "/"]

    while stack:
        cur = stack.pop()
        for fp, ent in list_children(base, cur):
            if is_dir_listing(base, fp):
                stack.append(fp.rstrip("/") + "/")
                continue
            rel = fp[len(root_dir) :].lstrip("/")
            out[rel] = file_size_from_entry(ent)

    return out

def main():
    src = os.environ["SRC_BASE"].rstrip("/")
    dst = os.environ["DST_BASE"].rstrip("/")
    root = os.environ["ROOT_PREFIX"].rstrip("/")
    if not root.startswith("/"):
        root = "/" + root

    a = walk_files(src, root)
    b = walk_files(dst, root)
    if a == b:
        print("verify ok: %d files, sizes match" % len(a))
        return 0

    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    mismatch = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    print("verify failed: src files=%d dst files=%d" % (len(a), len(b)))
    for k in only_a[:50]:
        print("only_in_src", k, a[k])
    for k in only_b[:50]:
        print("only_in_dst", k, b[k])
    for k in mismatch[:50]:
        print("size_mismatch", k, a[k], b[k])
    if len(only_a) > 50 or len(only_b) > 50 or len(mismatch) > 50:
        print("... truncated ...")
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
PY

  VERIFY_B64="$(base64 <"$VERIFY_TMP" | tr -d '\n')"
  rm -f "$VERIFY_TMP"
  trap - EXIT

  echo "$LOG_PREFIX verify pod: ${VERIFY_POD} (image ${VERIFY_IMAGE})"

  cleanup_verify() {
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" delete pod "$VERIFY_POD" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap cleanup_verify EXIT

  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" run "$VERIFY_POD" \
    --restart=Never \
    --image="$VERIFY_IMAGE" \
    --env="SRC_BASE=${SOURCE_FILER_HTTP}" \
    --env="DST_BASE=${TARGET_FILER_HTTP}" \
    --env="ROOT_PREFIX=${SYNC_PATH}" \
    --env="VERIFY_B64=${VERIFY_B64}" \
    --command -- /bin/sh -c '
set -eu
printf "%s" "$VERIFY_B64" | base64 -d > /tmp/verify.py
python3 /tmp/verify.py
'

  echo "$LOG_PREFIX waiting for verify pod..."
  v_phase="$(wait_pod_terminal "$VERIFY_POD" 900)"
  echo "$LOG_PREFIX verify pod logs (${VERIFY_POD}):"
  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" logs "$VERIFY_POD" 2>/dev/null || true
  v_exit="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$VERIFY_POD" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo 1)"
  cleanup_verify
  trap - EXIT

  if [[ "$v_phase" != "Succeeded" || "$v_exit" != "0" ]]; then
    echo "$LOG_PREFIX verify failed: phase=${v_phase} exit=${v_exit}" >&2
    "${KUBECTL[@]}" -n "$K8S_NAMESPACE" describe pod "$VERIFY_POD" >&2 || true
    exit 5
  fi

  echo "$LOG_PREFIX success: filer sync window completed and tree verify passed."
  exit 0
fi

# ---- s3 (rclone) mode ----
LOG_PREFIX="[rclone-copy-verify]"
echo "$LOG_PREFIX --mode s3: rclone expects SeaweedFS S3-compatible API base URLs (typically :8333)." >&2
echo "$LOG_PREFIX Do not use filer file HTTP URLs (e.g. :8888) as rclone s3 endpoints; that is the wrong protocol." >&2
prompt_required SOURCE_ENDPOINT "Source S3 API endpoint for rclone (host:port or http[s]://host:port; usually :8333)"
prompt_required TARGET_ENDPOINT "Target S3 API endpoint for rclone (host:port or http[s]://host:port; usually :8333)"

SOURCE_ENDPOINT="$(normalize_endpoint "$SOURCE_ENDPOINT")"
TARGET_ENDPOINT="$(normalize_endpoint "$TARGET_ENDPOINT")"

prompt_required SOURCE_FILER_HTTP "Source filer base URL for preflight (host:port or http[s]://host:port)"
prompt_required TARGET_FILER_HTTP "Target filer base URL for preflight (host:port or http[s]://host:port)"

SOURCE_FILER_HTTP="$(strip_trailing_slash "$(normalize_endpoint "$SOURCE_FILER_HTTP")")"
TARGET_FILER_HTTP="$(strip_trailing_slash "$(normalize_endpoint "$TARGET_FILER_HTTP")")"

prompt_required SRC_ACCESS_KEY_ID "Source access key ID"
prompt_required SRC_SECRET_ACCESS_KEY "Source secret access key" "true"

DST_ACCESS_KEY_ID="${DST_ACCESS_KEY_ID:-$SRC_ACCESS_KEY_ID}"
DST_SECRET_ACCESS_KEY="${DST_SECRET_ACCESS_KEY:-$SRC_SECRET_ACCESS_KEY}"

preflight_filer_http_bucket "source" "$SOURCE_FILER_HTTP" "$BUCKET_NAME" "$BUCKET_FILER_PREFIX"
preflight_filer_http_bucket "target" "$TARGET_FILER_HTTP" "$BUCKET_NAME" "$BUCKET_FILER_PREFIX"
preflight_rclone_s3_bucket_list

POD_NAME="rclone-copy-verify-$(date +%s)"

echo "$LOG_PREFIX namespace: ${K8S_NAMESPACE}"
if [[ -n "$KUBECONFIG_PATH" ]]; then
  echo "$LOG_PREFIX kubeconfig: ${KUBECONFIG_PATH}"
fi
echo "$LOG_PREFIX pod: ${POD_NAME}"
echo "$LOG_PREFIX bucket: ${BUCKET_NAME}"
echo "$LOG_PREFIX rclone source (S3): ${SOURCE_ENDPOINT}"
echo "$LOG_PREFIX rclone target (S3): ${TARGET_ENDPOINT}"
echo "$LOG_PREFIX preflight source filer (HTTP): ${SOURCE_FILER_HTTP}"
echo "$LOG_PREFIX preflight target filer (HTTP): ${TARGET_FILER_HTTP}"
echo "$LOG_PREFIX filer bucket prefix: ${BUCKET_FILER_PREFIX}"
echo "$LOG_PREFIX creating pod..."

cleanup() {
  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" delete pod "$POD_NAME" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${KUBECTL[@]}" -n "$K8S_NAMESPACE" run "$POD_NAME" \
  --restart=Never \
  --image="$RCLONE_IMAGE" \
  --env="BUCKET_NAME=${BUCKET_NAME}" \
  --env="SOURCE_ENDPOINT=${SOURCE_ENDPOINT}" \
  --env="TARGET_ENDPOINT=${TARGET_ENDPOINT}" \
  --env="SRC_ACCESS_KEY_ID=${SRC_ACCESS_KEY_ID}" \
  --env="SRC_SECRET_ACCESS_KEY=${SRC_SECRET_ACCESS_KEY}" \
  --env="DST_ACCESS_KEY_ID=${DST_ACCESS_KEY_ID}" \
  --env="DST_SECRET_ACCESS_KEY=${DST_SECRET_ACCESS_KEY}" \
  --env="SRC_REGION=${SRC_REGION}" \
  --env="DST_REGION=${DST_REGION}" \
  --command -- /bin/sh -c '
set -eu
echo "[pod] rclone version:"
rclone version

echo "[pod] creating source and target remotes"
rclone config create src s3 \
  provider Other \
  env_auth false \
  access_key_id "$SRC_ACCESS_KEY_ID" \
  secret_access_key "$SRC_SECRET_ACCESS_KEY" \
  region "$SRC_REGION" \
  endpoint "$SOURCE_ENDPOINT" \
  force_path_style true >/dev/null

rclone config create dst s3 \
  provider Other \
  env_auth false \
  access_key_id "$DST_ACCESS_KEY_ID" \
  secret_access_key "$DST_SECRET_ACCESS_KEY" \
  region "$DST_REGION" \
  endpoint "$TARGET_ENDPOINT" \
  force_path_style true >/dev/null

echo "[pod] sync src:${BUCKET_NAME} -> dst:${BUCKET_NAME}"
rclone sync "src:${BUCKET_NAME}" "dst:${BUCKET_NAME}" \
  --fast-list \
  --checkers 16 \
  --transfers 16 \
  --s3-no-check-bucket \
  --progress

echo "[pod] verify with byte-level downloads"
if rclone check "src:${BUCKET_NAME}" "dst:${BUCKET_NAME}" \
  --one-way \
  --download \
  --checkers 16 \
  --s3-no-check-bucket \
  --progress; then
  echo "[pod] verification passed: no differences detected."
else
  echo "[pod] verification failed: differences detected." >&2
  exit 42
fi
'

echo "$LOG_PREFIX waiting for pod completion..."
if ! "${KUBECTL[@]}" -n "$K8S_NAMESPACE" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s >/dev/null 2>&1; then
  echo "$LOG_PREFIX pod did not become Ready; printing describe output." >&2
  "${KUBECTL[@]}" -n "$K8S_NAMESPACE" describe pod "$POD_NAME" >&2 || true
fi

"${KUBECTL[@]}" -n "$K8S_NAMESPACE" logs -f "$POD_NAME" || true

PHASE="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
EXIT_CODE="$("${KUBECTL[@]}" -n "$K8S_NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo 1)"

echo "$LOG_PREFIX pod phase: ${PHASE}, exit code: ${EXIT_CODE}"
if [[ "$EXIT_CODE" != "0" ]]; then
  echo "$LOG_PREFIX copy/verify failed." >&2
  exit "$EXIT_CODE"
fi

echo "$LOG_PREFIX success: bucket copy and verification completed."

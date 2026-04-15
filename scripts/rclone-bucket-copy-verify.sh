#!/usr/bin/env bash
# Copy one S3 bucket from a source S3 endpoint to a target S3 endpoint using rclone
# inside a short-lived pod in the target cluster, then verify integrity and report failures.
#
# Designed for WSL/bash operators: run this from your workstation where kubectl points
# at the target cluster context.
#
# Preflight (before creating the rclone pod):
# - Verifies each endpoint responds like a SeaweedFS filer HTTP API (GET /status).
# - Verifies the bucket path exists as a directory listing under ${BUCKET_FILER_PREFIX}/<bucket>/
#   (GET with Accept: application/json). Default prefix is /buckets.
# - Verifies rclone can list the bucket on both S3 endpoints (runs a tiny ephemeral pod
#   in the target namespace, then deletes it).
#
# Important SeaweedFS endpoint mismatch:
# - SeaweedFS "filer" HTTP is commonly on :8888 and is NOT the S3 API that rclone's
#   `s3` backend expects (SeaweedFS documents S3 for rclone on :8333).
# - If you only have :8888 exposed on the network, use an in-cluster S3 endpoint for
#   rclone (often `http://<filer-s3-service>.<ns>.svc.cluster.local:8333`) or expose S3.
#
# Prompts:
# - Bucket name
# - Source S3 endpoint (host:port or http[s]://host:port) — must be S3 API (usually :8333)
# - Target S3 endpoint (host:port or http[s]://host:port) — must be S3 API (usually :8333)
# - Filer HTTP base URL for preflight checks (host:port or http[s]://host:port) — usually :8888
#
# Optional environment variables:
# - K8S_NAMESPACE         (optional; if unset, script prompts)
# - KUBECONFIG_PATH       (optional explicit kubeconfig path)
# - SRC_ACCESS_KEY_ID     (required if not prompted)
# - SRC_SECRET_ACCESS_KEY (required if not prompted)
# - DST_ACCESS_KEY_ID     (defaults to SRC_ACCESS_KEY_ID)
# - DST_SECRET_ACCESS_KEY (defaults to SRC_SECRET_ACCESS_KEY)
# - SRC_REGION            (default: us-east-1)
# - DST_REGION            (default: us-east-1)
# - RCLONE_IMAGE          (default: rclone/rclone:1.68.2)
# - SOURCE_FILER_HTTP     (optional; if unset, script prompts)
# - TARGET_FILER_HTTP     (optional; if unset, script prompts)
# - SKIP_RCLONE_PREFLIGHT (optional; set to 1 to skip the in-cluster rclone list-bucket preflight)
# - BUCKET_FILER_PREFIX   (optional; default /buckets) filer path prefix before /<bucket> for HTTP checks
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

require_cmd kubectl
require_cmd date
require_cmd curl
require_cmd python3

usage() {
  cat <<'EOF'
Usage: rclone-bucket-copy-verify.sh [--kubeconfig /path/to/kubeconfig] [--namespace NAMESPACE]

Options:
  --kubeconfig PATH   Use this kubeconfig file for all kubectl calls.
  --namespace NS      Kubernetes namespace (overrides K8S_NAMESPACE env).
  -h, --help          Show this help.
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
  # Some proxies/normalizers may return the bucket path with or without a trailing slash.
  if path.rstrip("/") != want.rstrip("/"):
    raise SystemExit(1)
' "$bucket" "$prefix" >/dev/null; then
    echo "$LOG_PREFIX preflight failed: ${name} bucket JSON listing did not look like a SeaweedFS filer directory response for bucket '$bucket'." >&2
    echo "$json" >&2
    exit 2
  fi
}

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
K8S_NAMESPACE="${K8S_NAMESPACE:-}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.68.2}"
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

LOG_PREFIX="[rclone-copy-verify]"

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

prompt_required K8S_NAMESPACE "Target namespace for rclone pod"
prompt_required BUCKET_NAME "Bucket name"
prompt_required SOURCE_ENDPOINT "Source S3 API endpoint for rclone (host:port or http[s]://host:port; usually :8333)"
prompt_required TARGET_ENDPOINT "Target S3 API endpoint for rclone (host:port or http[s]://host:port; usually :8333)"

SOURCE_ENDPOINT="$(normalize_endpoint "$SOURCE_ENDPOINT")"
TARGET_ENDPOINT="$(normalize_endpoint "$TARGET_ENDPOINT")"

prompt_required SOURCE_FILER_HTTP "Source filer HTTP base URL for preflight (host:port or http[s]://host:port; usually :8888)"
prompt_required TARGET_FILER_HTTP "Target filer HTTP base URL for preflight (host:port or http[s]://host:port; usually :8888)"

SOURCE_FILER_HTTP="$(normalize_endpoint "$SOURCE_FILER_HTTP")"
TARGET_FILER_HTTP="$(normalize_endpoint "$TARGET_FILER_HTTP")"

# Credentials: destination defaults to source unless explicitly set.
prompt_required SRC_ACCESS_KEY_ID "Source access key ID"
prompt_required SRC_SECRET_ACCESS_KEY "Source secret access key" "true"

DST_ACCESS_KEY_ID="${DST_ACCESS_KEY_ID:-$SRC_ACCESS_KEY_ID}"
DST_SECRET_ACCESS_KEY="${DST_SECRET_ACCESS_KEY:-$SRC_SECRET_ACCESS_KEY}"

BUCKET_FILER_PREFIX="${BUCKET_FILER_PREFIX:-/buckets}"
BUCKET_FILER_PREFIX="$(strip_trailing_slash "$BUCKET_FILER_PREFIX")"

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
echo "$LOG_PREFIX preflight source filer (HTTP): $(strip_trailing_slash "$SOURCE_FILER_HTTP")"
echo "$LOG_PREFIX preflight target filer (HTTP): $(strip_trailing_slash "$TARGET_FILER_HTTP")"
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

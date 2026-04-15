#!/usr/bin/env bash
# Copy one S3 bucket from source endpoint to target endpoint using rclone in-cluster,
# then verify integrity and report failures.
#
# Designed for WSL/bash operators: run this from your workstation where kubectl points
# at the target cluster context.
#
# Prompts:
# - Bucket name
# - Source S3 endpoint (e.g. http://10.0.0.10:8333)
# - Target S3 endpoint (e.g. http://10.0.0.20:8333)
#
# Optional environment variables:
# - K8S_NAMESPACE         (default: seaweedfs)
# - SRC_ACCESS_KEY_ID     (required if not prompted)
# - SRC_SECRET_ACCESS_KEY (required if not prompted)
# - DST_ACCESS_KEY_ID     (defaults to SRC_ACCESS_KEY_ID)
# - DST_SECRET_ACCESS_KEY (defaults to SRC_SECRET_ACCESS_KEY)
# - SRC_REGION            (default: us-east-1)
# - DST_REGION            (default: us-east-1)
# - RCLONE_IMAGE          (default: rclone/rclone:1.68.2)
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

require_cmd kubectl
require_cmd date

K8S_NAMESPACE="${K8S_NAMESPACE:-seaweedfs}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.68.2}"
SRC_REGION="${SRC_REGION:-us-east-1}"
DST_REGION="${DST_REGION:-us-east-1}"

prompt_required BUCKET_NAME "Bucket name"
prompt_required SOURCE_ENDPOINT "Source S3 endpoint (host:port or http[s]://host:port)"
prompt_required TARGET_ENDPOINT "Target S3 endpoint (host:port or http[s]://host:port)"

SOURCE_ENDPOINT="$(normalize_endpoint "$SOURCE_ENDPOINT")"
TARGET_ENDPOINT="$(normalize_endpoint "$TARGET_ENDPOINT")"

# Credentials: destination defaults to source unless explicitly set.
prompt_required SRC_ACCESS_KEY_ID "Source access key ID"
prompt_required SRC_SECRET_ACCESS_KEY "Source secret access key" "true"

DST_ACCESS_KEY_ID="${DST_ACCESS_KEY_ID:-$SRC_ACCESS_KEY_ID}"
DST_SECRET_ACCESS_KEY="${DST_SECRET_ACCESS_KEY:-$SRC_SECRET_ACCESS_KEY}"

POD_NAME="rclone-copy-verify-$(date +%s)"
LOG_PREFIX="[rclone-copy-verify]"

echo "$LOG_PREFIX namespace: ${K8S_NAMESPACE}"
echo "$LOG_PREFIX pod: ${POD_NAME}"
echo "$LOG_PREFIX bucket: ${BUCKET_NAME}"
echo "$LOG_PREFIX source: ${SOURCE_ENDPOINT}"
echo "$LOG_PREFIX target: ${TARGET_ENDPOINT}"
echo "$LOG_PREFIX creating pod..."

cleanup() {
  kubectl -n "$K8S_NAMESPACE" delete pod "$POD_NAME" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$K8S_NAMESPACE" run "$POD_NAME" \
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
if ! kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s >/dev/null 2>&1; then
  echo "$LOG_PREFIX pod did not become Ready; printing describe output." >&2
  kubectl -n "$K8S_NAMESPACE" describe pod "$POD_NAME" >&2 || true
fi

kubectl -n "$K8S_NAMESPACE" logs -f "$POD_NAME" || true

PHASE="$(kubectl -n "$K8S_NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
EXIT_CODE="$(kubectl -n "$K8S_NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo 1)"

echo "$LOG_PREFIX pod phase: ${PHASE}, exit code: ${EXIT_CODE}"
if [[ "$EXIT_CODE" != "0" ]]; then
  echo "$LOG_PREFIX copy/verify failed." >&2
  exit "$EXIT_CODE"
fi

echo "$LOG_PREFIX success: bucket copy and verification completed."

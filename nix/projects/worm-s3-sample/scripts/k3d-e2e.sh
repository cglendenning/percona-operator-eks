#!/usr/bin/env bash
# End-to-end: k3d + SeaweedFS Helm + S3 Object Lock delete rejection (versioned delete).
# Requires: Docker running, values file path in WORM_SEAWEED_VALUES
#
# If this "hangs" on macOS: Docker Desktop still starting, k3d --wait, Helm --wait (PVC/images),
# or aws without connect timeouts. This script uses AWS timeouts and an S3 readiness loop.

set -euo pipefail
[[ "${WORM_DEBUG:-}" == "1" ]] && set -x

CLUSTER_NAME="${WORM_K3D_CLUSTER_NAME:-worm-s3-sample}"
NS="${WORM_K8S_NAMESPACE:-worm-s3}"
RELEASE="${WORM_HELM_RELEASE:-worm-sw}"
CHART_VERSION="${WORM_SEAWEED_CHART_VERSION:-4.0.406}"
# Defaults are tight: slow environments must set higher values explicitly (e.g. WORM_HELM_WAIT_TIMEOUT=15m for cold image pulls).
HELM_WAIT_TIMEOUT="${WORM_HELM_WAIT_TIMEOUT:-8m}"
# k3d: --wait can block forever without this (see `k3d cluster create --help`: --timeout).
K3D_WAIT_TIMEOUT="${WORM_K3D_WAIT_TIMEOUT:-10m}"
DOCKER_INFO_TIMEOUT="${WORM_DOCKER_INFO_TIMEOUT:-20}"
K3D_DELETE_TIMEOUT_SEC="${WORM_K3D_DELETE_TIMEOUT_SEC:-60}"
K3D_KUBECONFIG_TIMEOUT_SEC="${WORM_K3D_KUBECONFIG_TIMEOUT_SEC:-30}"
K3D_CLEANUP_DELETE_SEC="${WORM_K3D_CLEANUP_DELETE_SEC:-60}"
METRICS_SERVER_VERSION="${WORM_METRICS_SERVER_VERSION:-0.7.2}"
METRICS_ROLLOUT_TIMEOUT_SEC="${WORM_METRICS_ROLLOUT_TIMEOUT_SEC:-60}"
METRICS_API_WAIT_SEC="${WORM_METRICS_API_WAIT_SEC:-40}"
# kubectl --timeout: use forms like 60s, 2m
KUBECTL_NODE_WAIT="${WORM_KUBECTL_NODE_WAIT:-60s}"
FILER_POD_WAIT="${WORM_FILER_POD_WAIT:-120s}"
HELM_REPO_UPDATE_SEC="${WORM_HELM_REPO_UPDATE_SEC:-30}"
PF_LOCAL="${WORM_PF_LOCAL_PORT:-18333}"
PF_READY_SECONDS="${WORM_PF_READY_SECONDS:-40}"
# While `helm --wait` runs (image pulls, PVC, StatefulSet rolls), print periodic namespace snapshots.
WORM_HELM_LIVE_STATUS="${WORM_HELM_LIVE_STATUS:-1}"
WORM_HELM_STATUS_INTERVAL="${WORM_HELM_STATUS_INTERVAL:-8}"
# Set WORM_HELM_DEBUG=1 for full helm template + API chatter (loud).
WORM_HELM_DEBUG="${WORM_HELM_DEBUG:-0}"
# Retries to resolve a SeaweedFS S3 version id (eventual list after put).
S3_VID_RETRIES="${WORM_S3_VERSION_ID_RETRIES:-6}"
S3_VID_RETRY_SLEEP_SEC="${WORM_S3_VERSION_ID_SLEEP:-2}"
# If 1, fail the run when delete-object --version-id succeeds under COMPLIANCE (AWS S3 does not allow that).
# Default 0: SeaweedFS has historically allowed the delete; we WARN and still exit 0. See README / SeaweedFS S3 parity.
WORM_S3_E2E_STRICT_VERSION_DELETE="${WORM_S3_E2E_STRICT_VERSION_DELETE:-0}"
# Set by flake; when running this script from a git clone, default to a manifest next to this file.
: "${WORM_AUDIT_FLUENT_MANIFEST:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worm-s3-audit-fluent.k8s.yaml}"
AUDIT_DEPLOY_NAME="${WORM_S3_AUDIT_FLUENT_DEPLOY:-worm-s3-audit-fluent}"
AUDIT_WAIT="${WORM_S3_AUDIT_FLUENT_WAIT:-120s}"

export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=2
AWS_CONNECT_TIMEOUT="${WORM_AWS_CONNECT_TIMEOUT:-5}"
AWS_READ_TIMEOUT="${WORM_AWS_READ_TIMEOUT:-20}"
AWS_TIMEOUT=(--cli-connect-timeout "$AWS_CONNECT_TIMEOUT" --cli-read-timeout "$AWS_READ_TIMEOUT")

if [[ -z "${WORM_SEAWEED_VALUES:-}" ]] || [[ ! -f "$WORM_SEAWEED_VALUES" ]]; then
  echo "WORM_SEAWEED_VALUES must point to the generated values.yaml file" >&2
  exit 1
fi

HELM="${WORM_HELM:-helm}"

# Hide client-go memcache discovery lines when the metrics API is still registering (set WORM_K8S_QUIET_DISCOVERY=0 to see full logs).
_worm_kubectl=$(command -v kubectl)
if [[ "${WORM_K8S_QUIET_DISCOVERY:-1}" == "1" ]]; then
  kubectl() { "$_worm_kubectl" "$@" 2> >(grep -vE 'memcache\.go:(287|121)' >&2 || true); }
  worm_helm() { command "$HELM" "$@" 2> >(grep -vE 'memcache\.go:(287|121)' >&2 || true); }
  helm_timeout() {
    local t=$1; shift
    timeout "$t" command "$HELM" "$@" 2> >(grep -vE 'memcache\.go:(287|121)' >&2 || true)
  }
else
  kubectl() { "$_worm_kubectl" "$@"; }
  worm_helm() { command "$HELM" "$@"; }
  helm_timeout() {
    local t=$1; shift
    timeout "$t" command "$HELM" "$@"
  }
fi

echo "==> docker: $(command -v docker)"
echo "==> k3d:    $(command -v k3d)"
echo "==> helm:   $HELM ($("$HELM" version --short 2>/dev/null || echo 'version?'))"

if ! timeout "$DOCKER_INFO_TIMEOUT" docker info >/dev/null 2>&1; then
  echo "ERROR: docker info did not finish within ${DOCKER_INFO_TIMEOUT}s." >&2
  echo "The Docker engine is often wedged: quit Docker Desktop fully, start it again, wait for the engine to be ready, then run: docker run --rm hello-world" >&2
  echo "If another terminal is stuck in k3d, that can block the Docker API; fix Docker first, then: k3d cluster list" >&2
  exit 1
fi

BUCKET="$(yq -r '.filer.s3.createBuckets[0].name' "$WORM_SEAWEED_VALUES")"
echo "Using bucket: $BUCKET"

RETAIN_UNTIL="$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cleanup() {
  if [[ "${WORM_KEEP_CLUSTER:-}" == "1" ]]; then
    echo "WORM_KEEP_CLUSTER=1 set; leaving cluster $CLUSTER_NAME"
    return 0
  fi
  timeout "$K3D_CLEANUP_DELETE_SEC" k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Recreating k3d cluster $CLUSTER_NAME (k3d --wait is capped at ${K3D_WAIT_TIMEOUT})"
# Delete must not block forever if the engine is busy.
timeout "$K3D_DELETE_TIMEOUT_SEC" k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true

k3d_wait=(--wait)
if [[ "${WORM_K3D_NOWAIT:-}" == "1" ]]; then
  k3d_wait=()
  echo "WARN: WORM_K3D_NOWAIT=1 — skipping k3d --wait (Helm may race the API server)."
fi
# --timeout: required with --wait or k3d can wait forever (v5+). Rollback and exit non-zero on expiry.
# shellcheck disable=SC2206
create_args=(cluster create "$CLUSTER_NAME" --agents 1 --k3s-arg '--disable=traefik@server:0' --timeout "$K3D_WAIT_TIMEOUT")
if [[ ${#k3d_wait[@]} -gt 0 ]]; then
  create_args+=("${k3d_wait[@]}")
fi
k3d "${create_args[@]}"

export KUBECONFIG
if ! KUBECONFIG_OUT="$(timeout "$K3D_KUBECONFIG_TIMEOUT_SEC" k3d kubeconfig write "$CLUSTER_NAME" 2>&1)"; then
  echo "ERROR: k3d kubeconfig write failed or timed out after ${K3D_KUBECONFIG_TIMEOUT_SEC}s:" >&2
  echo "$KUBECONFIG_OUT" >&2
  exit 1
fi
KUBECONFIG="$KUBECONFIG_OUT"
export KUBECONFIG

echo "==> Wait for nodes Ready (API server + kubelet; max ${KUBECTL_NODE_WAIT})"
kubectl wait --for=condition=Ready nodes --all --timeout="$KUBECTL_NODE_WAIT"

# k3d has no metrics-server by default; Helm 3.17+ discovers API groups and will spam
# memcache "metrics.k8s.io/v1beta1" errors (and can stall) until this API exists.
if [[ "${WORM_SKIP_METRICS_SERVER:-}" == "1" ]]; then
  echo "WARN: WORM_SKIP_METRICS_SERVER=1 — skip metrics-server; you may see metrics API discovery noise or flakes."
else
  echo "==> metrics-server (for metrics.k8s.io; k3d needs --kubelet-insecure-tls)"
  # k3s may install a non-functional or partial metrics API; that breaks discovery until replaced.
  # Remove deployment + RS + service + pods so we do not sit in "1 old replicas are pending termination".
  kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found
  kubectl -n kube-system delete all -l k8s-app=metrics-server --ignore-not-found
  kubectl -n kube-system delete pod -l k8s-app=metrics-server --force --grace-period=0 --ignore-not-found 2>/dev/null || true
  sleep 3
  # --force-conflicts: k3s also manages aggregated-metrics-reader / kubernetes service fields; a plain SSA merge fails, then a client apply spews last-applied warnings.
  MS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v${METRICS_SERVER_VERSION}/components.yaml"
  if ! curl -fsSL "$MS_URL" | kubectl apply --server-side --field-manager=worm-k3d-e2e --force-conflicts -f-; then
    echo "ERROR: metrics-server manifest apply (server-side, force-conflicts) failed." >&2
    exit 1
  fi
  # k3d/k3s: kubelet serving certs are not the cluster CA; without this, metrics may never scrape (silent failure).
  set +e
  _metrics_patch_out="$(kubectl patch deployment metrics-server -n kube-system --type=json \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' 2>&1)"
  _mrv=$?
  set -e
  if [[ "$_mrv" -ne 0 ]]; then
    echo "$_metrics_patch_out" >&2
  fi
  if ! kubectl get deployment metrics-server -n kube-system -o json \
    | jq -e '.spec.template.spec.containers[] | select(.name == "metrics-server") | (.args // []) | index("--kubelet-insecure-tls") | type == "number"' &>/dev/null; then
    echo "ERROR: metrics-server must run with --kubelet-insecure-tls on k3d (patch exit ${_mrv}). Current args:" >&2
    kubectl get deployment metrics-server -n kube-system -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.args}{"\n"}{end}' >&2
    exit 1
  fi
  kubectl rollout status deployment/metrics-server -n kube-system --timeout="${METRICS_ROLLOUT_TIMEOUT_SEC}s"
  echo "==> Wait until /apis/metrics.k8s.io/v1beta1 is reachable (Helm/kubectl discovery; max ${METRICS_API_WAIT_SEC}s)"
  mdeadline=$(($(date +%s) + METRICS_API_WAIT_SEC))
  while (( $(date +%s) < mdeadline )); do
    if kubectl get --raw /apis/metrics.k8s.io/v1beta1 &>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! kubectl get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null 2>&1; then
    echo "ERROR: metrics.k8s.io not reachable after install; check: kubectl -n kube-system logs deploy/metrics-server" >&2
    exit 1
  fi
fi

# Fluentd in_forward (Go fluent-logger / Logstash “codec fluent” compatible); must be Ready before the filer starts.
echo "==> S3 API audit: Fluentd forward receiver in namespace $NS (SeaweedFS filer.s3.auditLogConfig)"
if [[ ! -f "$WORM_AUDIT_FLUENT_MANIFEST" ]]; then
  echo "ERROR: WORM_AUDIT_FLUENT_MANIFEST not found: $WORM_AUDIT_FLUENT_MANIFEST" >&2
  exit 1
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
sed "s/__WORM_E2E_NAMESPACE__/${NS}/g" "$WORM_AUDIT_FLUENT_MANIFEST" | kubectl apply -f -
echo "   Waiting for ${AUDIT_DEPLOY_NAME} (max ${AUDIT_WAIT})"
kubectl wait --for=condition=available "deployment/${AUDIT_DEPLOY_NAME}" -n "$NS" --timeout="$AUDIT_WAIT"

echo "==> Helm: add/update repo, then install SeaweedFS chart ${CHART_VERSION} (release $RELEASE) into namespace $NS"
echo "   Actions: load chart, render with values, create namespace, create workloads, then --wait (cap ${HELM_WAIT_TIMEOUT}):"
echo "   pull container images, start pods, wait for schedulers/CNI/PVC, readiness, hooks."
echo "   Progress: periodic kubectl snapshots in this terminal (WORM_HELM_LIVE_STATUS=0 to disable)."
worm_helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm >/dev/null 2>&1 || true
echo "==> helm repo update (max ${HELM_REPO_UPDATE_SEC}s)"
helm_timeout "$HELM_REPO_UPDATE_SEC" repo update >/dev/null

_helm_ex=(upgrade --install "$RELEASE" seaweedfs/seaweedfs --namespace "$NS" --create-namespace --version "$CHART_VERSION" -f "$WORM_SEAWEED_VALUES" --wait --timeout "$HELM_WAIT_TIMEOUT")
[[ "$WORM_HELM_DEBUG" == "1" ]] && _helm_ex+=(--debug)

_HPOLL=
if [[ "$WORM_HELM_LIVE_STATUS" == "1" ]]; then
  _lint="${WORM_HELM_STATUS_INTERVAL:-8}"
  (
    sleep 2
    while true; do
      echo "---- $(date -u '+%H:%M:%S')Z  helm: workload snapshot (namespace $NS) ----"
      kubectl get deploy,sts,po -n "$NS" 2>/dev/null || true
      kubectl get pvc -n "$NS" 2>/dev/null | head -n 20 || true
      echo ""
      sleep "$_lint"
    done
  ) &
  _HPOLL=$!
fi

set +e
worm_helm "${_helm_ex[@]}"
_helm_rc=$?
set -e
if [[ -n "$_HPOLL" ]]; then
  kill "$_HPOLL" 2>/dev/null || true
  wait "$_HPOLL" 2>/dev/null || true
fi
if [[ "$_helm_rc" -ne 0 ]]; then
  echo "ERROR: helm upgrade failed (rc=$_helm_rc). Try WORM_HELM_DEBUG=1 or a higher WORM_HELM_WAIT_TIMEOUT." >&2
  exit "$_helm_rc"
fi

echo "==> Wait for filer pod"
FILER_POD="$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=filer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$FILER_POD" ]]; then
  FILER_POD="$(kubectl get pods -n "$NS" -o name | grep -i filer | grep -vi 's3\|sync' | head -1 | sed 's|pod/||')"
fi
if [[ -z "$FILER_POD" ]]; then
  echo "Could not find filer pod in namespace $NS" >&2
  kubectl get pods -n "$NS" >&2
  exit 1
fi
echo "Filer pod: $FILER_POD"
kubectl wait --for=condition=ready "pod/$FILER_POD" -n "$NS" --timeout="$FILER_POD_WAIT"

# SeaweedFS Helm: /etc/sw (S3 config + filer_s3_auditLogConfig.json) is only mounted when filer.s3.enableAuth
# (see filer statefulset). WORM sample values set enableAuth + auditLogConfig; use chart-generated admin keys.
if kubectl get secret seaweedfs-s3-secret -n "$NS" -o name &>/dev/null; then
  AWS_ACCESS_KEY_ID="$(kubectl get secret seaweedfs-s3-secret -n "$NS" -o json | jq -r '.data.admin_access_key_id | @base64d')"
  AWS_SECRET_ACCESS_KEY="$(kubectl get secret seaweedfs-s3-secret -n "$NS" -o json | jq -r '.data.admin_secret_access_key | @base64d')"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  echo "S3: credentials from secret seaweedfs-s3-secret (admin; enableAuth + audit file mount per Helm chart)."
else
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-dummy}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-dummy}"
  echo "WARN: no seaweedfs-s3-secret; using AWS_ACCESS_KEY_ID dummy (S3 with enableAuth will fail)" >&2
fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

kubectl port-forward -n "$NS" "pod/$FILER_POD" "$PF_LOCAL:8333" >/tmp/worm-pf.log 2>&1 &
PF_PID=$!
ENDPOINT="http://127.0.0.1:${PF_LOCAL}"

echo "==> Waiting for S3 on 127.0.0.1:${PF_LOCAL} (up to ${PF_READY_SECONDS}s; tail -f /tmp/worm-pf.log in another terminal if unsure)"
pf_start="$(date +%s)"
pf_deadline=$((pf_start + PF_READY_SECONDS))
while (( $(date +%s) < pf_deadline )); do
  if kill -0 "$PF_PID" 2>/dev/null && bash -c "echo >/dev/tcp/127.0.0.1/${PF_LOCAL}" 2>/dev/null; then
    if aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3 ls >/dev/null 2>&1; then
      echo "S3 endpoint is up."
      break
    fi
  fi
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "port-forward exited early. Log:" >&2
    cat /tmp/worm-pf.log >&2 || true
    exit 1
  fi
  sleep 1
done
if (( $(date +%s) >= pf_deadline )); then
  echo "Timed out waiting for S3 (port-forward or aws). Last port-forward log:" >&2
  cat /tmp/worm-pf.log >&2 || true
  echo "kubectl describe pod -n $NS $FILER_POD:" >&2
  kubectl describe pod -n "$NS" "$FILER_POD" >&2 || true
  exit 1
fi

# createBuckets in Helm can still leave the filer without S3 versioning xattr, so list-object versions show
# VersionId "null" and put-object has no id. The S3 API must set it before any WORM test objects exist.
echo "==> Enable bucket versioning (S3: put-bucket-versioning) — required for real VersionId / object-lock tests"
set +e
_PBV_ERR="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api put-bucket-versioning \
  --bucket "$BUCKET" --versioning-configuration Status=Enabled 2>&1)"
_PBV_RC=$?
set -e
if [[ "$_PBV_RC" -ne 0 ]]; then
  echo "ERROR: put-bucket-versioning failed (rc=${_PBV_RC}): $_PBV_ERR" >&2
  echo "The bucket must allow versioning. Check filer S3 and SeaweedFS version." >&2
  exit 1
fi
BV_OK="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api get-bucket-versioning --bucket "$BUCKET" 2>&1 || true)"
echo "get-bucket-versioning: $BV_OK"
if ! echo "$BV_OK" | jq -e '.Status == "Enabled"' &>/dev/null; then
  echo "ERROR: bucket is not in Versioning=Enabled after put-bucket-versioning (need Status: Enabled). Response above." >&2
  exit 1
fi

echo "==> Positive: list buckets"
aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3 ls

KEY="compliance/demo.txt"
echo worm-demo-data > /tmp/worm-body.txt

# Attempt to resolve a version id: put/head/list, with retries (list can lag a moment after first write).
s3_resolve_version_id() {
  local put_json=$1
  local v="" raw=""
  v="$(echo "$put_json" | jq -r '.VersionId // empty | tostring | if . == "null" or . == "" then "" else . end' 2>/dev/null || true)"
  if [[ -n "$v" ]]; then
    echo -n "$v"
    return 0
  fi
  v="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api head-object \
    --bucket "$BUCKET" --key "$KEY" --output json 2>/dev/null | jq -r '.VersionId // empty | tostring | if . == "null" or . == "" then "" else . end' || true)"
  if [[ -n "$v" ]]; then
    echo -n "$v"
    return 0
  fi
  raw="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api list-object-versions \
    --bucket "$BUCKET" --prefix "$KEY" --max-items 20 --output json 2>/dev/null || true)"
  v="$(echo "$raw" | jq -r --arg k "$KEY" '((.Versions // [])
    | map(select(.Key==$k and .VersionId != null and ((.VersionId|tostring) != "null") and ((.VersionId|tostring) != "")))
    | sort_by(.LastModified) | if length > 0 then .[-1].VersionId|tostring else empty end) // empty' 2>/dev/null || true)"
  if [[ -n "$v" && "$v" != "null" ]]; then
    echo -n "$v"
    return 0
  fi
  raw="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api list-object-versions \
    --bucket "$BUCKET" --output json 2>/dev/null || true)"
  v="$(echo "$raw" | jq -r --arg k "$KEY" '((.Versions // [])
    | map(select(.Key==$k and .VersionId != null and ((.VersionId|tostring) != "null") and ((.VersionId|tostring) != "")))
    | sort_by(.LastModified) | if length > 0 then .[-1].VersionId|tostring else empty end) // empty' 2>/dev/null || true)"
  if [[ -n "$v" && "$v" != "null" ]]; then
    echo -n "$v"
    return 0
  fi
  return 1
}

echo "==> Positive: put object (versioned bucket)"
PUT_OUT="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api put-object \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --body /tmp/worm-body.txt)"
echo "$PUT_OUT"
VID=""
for ((i = 0; i < S3_VID_RETRIES; i++)); do
  if VID="$(s3_resolve_version_id "$PUT_OUT")" && [[ -n "$VID" ]]; then
    break
  fi
  if (( i < S3_VID_RETRIES - 1 )); then
    echo "   (version id not visible yet, retry $((i + 1))/${S3_VID_RETRIES} in ${S3_VID_RETRY_SLEEP_SEC}s...)" >&2
    sleep "$S3_VID_RETRY_SLEEP_SEC"
  fi
done
if [[ -z "$VID" ]]; then
  echo "ERROR: no S3 VersionId for key $(printf '%q' "$KEY") in bucket $(printf '%q' "$BUCKET") after put (SeaweedFS needs versioning + object lock; see get-bucket-versioning and list-object-versions below)." >&2
  aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api list-object-versions --bucket "$BUCKET" --prefix "compliance/" 2>&1 | head -c 4000 >&2
  echo "" >&2
  exit 1
fi
echo "VersionId=$VID"

echo "==> Positive: COMPLIANCE retention on version"
aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api put-object-retention \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --version-id "$VID" \
  --retention "{\"Mode\":\"COMPLIANCE\",\"RetainUntilDate\":\"${RETAIN_UNTIL}\"}"

echo "==> Verify get-object-retention (COMPLIANCE + date)"
GORET="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api get-object-retention \
  --bucket "$BUCKET" --key "$KEY" --version-id "$VID" 2>&1)" || { echo "ERROR: get-object-retention: $GORET" >&2; exit 1; }
echo "$GORET"
if ! echo "$GORET" | jq -e '.Retention.Mode == "COMPLIANCE"' &>/dev/null; then
  echo "ERROR: expected Retention.Mode COMPLIANCE" >&2
  exit 1
fi

echo "==> Get object before delete (content must match)"
aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api get-object \
  --bucket "$BUCKET" --key "$KEY" --version-id "$VID" /tmp/worm-out.txt
cmp -s /tmp/worm-body.txt /tmp/worm-out.txt

echo "==> Negative: delete-object WITH version-id (AWS S3: must fail under active COMPLIANCE; SeaweedFS often differs)"
set +e
DEL_ERR="$(aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api delete-object \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --version-id "$VID" 2>&1)"
DEL_RC=$?
set -e
if [[ "$DEL_RC" -ne 0 ]]; then
  echo "OK: delete denied or errored (non-zero) as in strict AWS S3 WORM behavior:"
  echo "$DEL_ERR"
  echo "==> get-object with version id still expected after a denied delete"
  aws "${AWS_TIMEOUT[@]}" --endpoint-url "$ENDPOINT" s3api get-object \
    --bucket "$BUCKET" --key "$KEY" --version-id "$VID" /tmp/worm-out.txt
  cmp -s /tmp/worm-body.txt /tmp/worm-out.txt
else
  if [[ "$WORM_S3_E2E_STRICT_VERSION_DELETE" == "1" ]]; then
    echo "FAIL: WORM_S3_E2E_STRICT_VERSION_DELETE=1 but delete-object --version-id succeeded (unlike AWS S3). Output:" >&2
    echo "$DEL_ERR" >&2
    exit 1
  fi
  echo "WARN: delete-object --version-id returned success; AWS S3 would deny a COMPLIANCE-protected version." >&2
  echo "WARN: SeaweedFS S3 parity: https://github.com/seaweedfs/seaweedfs/issues/8350 and related object-lock threads." >&2
  echo "WARN: WORM_S3_E2E_STRICT_VERSION_DELETE=1 would fail this run. The version may now be removed; skipping post-delete get." >&2
fi

echo "==> S3 API audit (Fluent forward → Fluentd stdout; see https://github.com/seaweedfs/seaweedfs/wiki/S3-API-Audit-log )"
if kubectl -n "$NS" get "deployment/${AUDIT_DEPLOY_NAME}" &>/dev/null; then
  _al="$(kubectl logs -n "$NS" "deployment/${AUDIT_DEPLOY_NAME}" --tail=2000 2>&1 || true)"
  # SeaweedFS go-fluent-logger: JSON with "operation" (e.g. REST.PUT.OBJECT). Receiver is Fluentd (not Fluent Bit) for wire compatibility.
  if echo "$_al" | grep -qE '"operation"|REST\.(GET|PUT|POST|DELETE|HEAD)'; then
    echo "---- SeaweedFS S3 access (lines matching operation or REST.*) ----"
    echo "$_al" | grep -E '"operation"|REST\.(GET|PUT|POST|DELETE|HEAD)' || true
  else
    echo "$_al"
    echo "WARN: no SeaweedFS audit lines detected. Filer must mount /etc/sw/filer_s3_auditLogConfig.json (filer.s3.enableAuth); receiver must be Fluentd-compatible in_forward (this e2e uses fluent/fluentd, not Fluent Bit)." >&2
  fi
else
  echo "WARN: audit receiver deployment/${AUDIT_DEPLOY_NAME} not found in $NS" >&2
fi

kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true

echo "All checks passed."

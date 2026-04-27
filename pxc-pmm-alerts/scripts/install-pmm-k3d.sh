#!/usr/bin/env bash
# Install PMM into an existing k3d cluster for local smoke tests (Apple Silicon friendly).
# Hard timeouts everywhere; failures exit non-zero immediately.
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_UI_SH="${_SCRIPT_DIR}/pmm-ui.sh"
_ENSURE_SH="${_SCRIPT_DIR}/pmm-k3d-ensure.sh"

PMM_NS="${PMM_NS:-pmm}"
REL="${REL:-pmm}"
CHART_REPO="${CHART_REPO:-https://percona.github.io/percona-helm-charts}"
# 3.7.x images may lack arm64; 3.5.x is known to pull on linux/arm64.
IMAGE_TAG="${IMAGE_TAG:-3.5.0}"
HELM_WAIT="${HELM_WAIT:-5m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
# Percona chart only creates pmm-secret on first `helm install`; for upgrades the Secret is never rendered.
# Set explicitly so PMM and kubectl stay in sync (local dev default is predictable).
PMM_BOOTSTRAP_PASSWORD="${PMM_BOOTSTRAP_PASSWORD:-pmm-local-dev}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }

need kubectl
need helm

echo "[install-pmm-k3d] ensuring namespace ${PMM_NS}"
kubectl create namespace "${PMM_NS}" --dry-run=client -o yaml | kubectl apply -f - --request-timeout=10s

echo "[install-pmm-k3d] helm upgrade --install (wait ${HELM_WAIT})"
helm upgrade --install "${REL}" pmm \
  --repo "${CHART_REPO}" \
  --namespace "${PMM_NS}" \
  --set service.type=ClusterIP \
  --set image.tag="${IMAGE_TAG}" \
  --set secret.pmm_password="${PMM_BOOTSTRAP_PASSWORD}" \
  --wait \
  --timeout "${HELM_WAIT}"

# Helm Secret manifest only on first install; (re)create if missing (e.g. prior rev never applied Secret).
if ! kubectl get secret "${REL}-secret" -n "${PMM_NS}" --request-timeout=10s &>/dev/null; then
  echo "[install-pmm-k3d] creating ${REL}-secret (not present after helm)"
  kubectl create secret generic "${REL}-secret" -n "${PMM_NS}" \
    --from-literal=PMM_ADMIN_PASSWORD="${PMM_BOOTSTRAP_PASSWORD}" \
    --request-timeout=10s
fi

echo "[install-pmm-k3d] waiting for StatefulSet rollout (${ROLLOUT_TIMEOUT})"
kubectl rollout status "statefulset/${REL}" -n "${PMM_NS}" --timeout="${ROLLOUT_TIMEOUT}" --request-timeout=10s

echo "[install-pmm-k3d] admin password (from secret ${REL}-secret):"
kubectl get secret "${REL}-secret" -n "${PMM_NS}" -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' --request-timeout=10s | base64 -d
echo ""

echo "[install-pmm-k3d] In-cluster HTTPS URL for Grafana/PMM API: https://monitoring-service.${PMM_NS}.svc.cluster.local"
echo "[install-pmm-k3d] Web UI: ${_ENSURE_SH} (if kube/API hangs) then: ${_UI_SH}"
echo "[install-pmm-k3d] done"

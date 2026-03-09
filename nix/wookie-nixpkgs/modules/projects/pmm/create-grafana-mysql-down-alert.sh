#!/usr/bin/env bash
set -euo pipefail

# This script runs under WSL (or any Linux shell) and creates a
# Grafana-managed "MySQL down" alert rule in PMM by:
#   - creating a helper pod in the PMM namespace
#   - exec'ing into that pod
#   - calling Grafana's unified alerting provisioning API
#
# It does NOT use PMM alert templates; it builds the rule directly
# against Grafana.

KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-pmm}"
PMM_NAMESPACE="${PMM_NAMESPACE:-pmm}"
PMM_ADMIN_PASSWORD="${PMM_ADMIN_PASSWORD:-admin}"

POD_NAME="grafana-alert-creator"

# Resolve directory of this script so we can find the JSON payload file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT_JSON="${SCRIPT_DIR}/grafana-mysql-down-alert.json"

echo "Using kube context: ${KUBE_CONTEXT}"
echo "Using PMM namespace: ${PMM_NAMESPACE}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH"
  exit 1
fi

echo "Verifying that pmm-server pod exists..."
if ! kubectl get pod -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" -l app=pmm-server >/dev/null 2>&1; then
  echo "ERROR: pmm-server pod not found in namespace ${PMM_NAMESPACE} (context ${KUBE_CONTEXT})"
  echo "Make sure your PMM stack is up before running this script."
  exit 1
fi

echo "Creating helper pod ${POD_NAME} (if not already present)..."
kubectl run "${POD_NAME}" \
  --image=curlimages/curl:8.11.0 \
  --restart=Never \
  --command -- sleep 3600 \
  -n "${PMM_NAMESPACE}" \
  --context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo "Waiting for helper pod to be Running..."
for i in $(seq 1 30); do
  phase="$(kubectl get pod "${POD_NAME}" -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  if [ "${phase}" = "Running" ]; then
    echo "Helper pod is Running."
    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "ERROR: helper pod did not reach Running phase in time (last phase: ${phase})"
    exit 1
  fi
  sleep 2
done

GRAFANA_URL_IN_POD="http://pmm-server.${PMM_NAMESPACE}.svc.cluster.local/graph"
ADMIN_USER="admin"

echo "Copying alert JSON payload into helper pod..."
kubectl cp "${ALERT_JSON}" "${PMM_NAMESPACE}/${POD_NAME}:/tmp/grafana-mysql-down-alert.json" --context "${KUBE_CONTEXT}"

echo "Exec'ing into helper pod to create Grafana alert rule..."
kubectl exec -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" "${POD_NAME}" -- sh -c '
set -euo pipefail

GRAFANA_URL="'"${GRAFANA_URL_IN_POD}"'"
ADMIN_USER="'"${ADMIN_USER}"'"
ADMIN_PASS="'"${PMM_ADMIN_PASSWORD}"'"

AUTH="-u ${ADMIN_USER}:${ADMIN_PASS}"

echo "Fetching Grafana datasources from ${GRAFANA_URL} ..."
DS_JSON=$(curl -sS ${AUTH} "${GRAFANA_URL}/api/datasources" || echo "")

DS_UID=$(printf "%s\n" "${DS_JSON}" | sed -n "s/.*\"type\":\"prometheus\"[^}]*\"uid\":\"\([^\"]*\)\".*/\1/p" | head -n1)

if [ -z "${DS_UID}" ]; then
  echo "ERROR: Could not determine Prometheus datasource UID for Grafana alert rule"
  exit 1
fi

echo "Using datasource UID: ${DS_UID}"
 
TEMPLATE_PATH="/tmp/grafana-mysql-down-alert.json"
PAYLOAD_PATH="/tmp/grafana-mysql-down-alert-resolved.json"

sed "s/__DATASOURCE_UID__/${DS_UID}/g" "${TEMPLATE_PATH}" > "${PAYLOAD_PATH}"

echo "Creating Grafana alert rule via provisioning API using payload file..."
CREATE_RESP=$(curl -sS -X POST ${AUTH} \
  -H "Content-Type: application/json" \
  -H "X-Disable-Provenance: true" \
  -d @"${PAYLOAD_PATH}" \
  "${GRAFANA_URL}/api/v1/provisioning/alert-rules" || echo "")

echo "Grafana API response:"
echo "${CREATE_RESP}"
'

echo "Cleaning up helper pod ${POD_NAME}..."
kubectl delete pod "${POD_NAME}" -n "${PMM_NAMESPACE}" --context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo "Done."


#!/usr/bin/env bash
#
# Cleanup Istio Multi-Primary Multi-Network Demo
#
set -euo pipefail

CTX_CLUSTER1="k3d-cluster-a"
CTX_CLUSTER2="k3d-cluster-b"

echo "=== Cleaning up Istio Multi-Primary Multi-Network Demo ==="
echo ""

# Delete hello service from cluster-a
echo "Deleting hello service from ${CTX_CLUSTER1}..."
kubectl delete namespace demo --context="${CTX_CLUSTER1}" --ignore-not-found=true

# Delete test namespace from cluster-b
echo "Deleting demo-dr namespace from ${CTX_CLUSTER2}..."
kubectl delete namespace demo-dr --context="${CTX_CLUSTER2}" --ignore-not-found=true
kubectl delete pod test-pod -n demo-dr --context="${CTX_CLUSTER2}" --ignore-not-found=true 2>/dev/null || true

# Delete Istio from both clusters
echo ""
echo "Deleting Istio from ${CTX_CLUSTER1}..."
kubectl delete namespace istio-system --context="${CTX_CLUSTER1}" --ignore-not-found=true

echo "Deleting Istio from ${CTX_CLUSTER2}..."
kubectl delete namespace istio-system --context="${CTX_CLUSTER2}" --ignore-not-found=true

# Clean up CRDs (optional - only if you want complete cleanup)
echo ""
read -p "Delete Istio CRDs? This will remove ALL Istio resources (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Deleting Istio CRDs from ${CTX_CLUSTER1}..."
  kubectl get crd -oname --context="${CTX_CLUSTER1}" | grep --color=never 'istio.io' | xargs kubectl delete --context="${CTX_CLUSTER1}" --ignore-not-found=true
  
  echo "Deleting Istio CRDs from ${CTX_CLUSTER2}..."
  kubectl get crd -oname --context="${CTX_CLUSTER2}" | grep --color=never 'istio.io' | xargs kubectl delete --context="${CTX_CLUSTER2}" --ignore-not-found=true
fi

# Delete k3d clusters
echo ""
read -p "Delete k3d clusters (${CTX_CLUSTER1} and ${CTX_CLUSTER2})? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Deleting k3d clusters..."
  k3d cluster delete cluster-a 2>/dev/null || echo "${CTX_CLUSTER1} not found"
  k3d cluster delete cluster-b 2>/dev/null || echo "${CTX_CLUSTER2} not found"
  
  echo "Removing shared Docker network..."
  docker network rm k3d-shared 2>/dev/null || echo "k3d-shared network not found"
fi

# Clean up nix build results
if [ -e "../result-cluster-a" ] || [ -e "../result-cluster-b" ]; then
  echo ""
  echo "Cleaning up Nix build artifacts..."
  rm -f ../result-cluster-a ../result-cluster-b
fi

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "To redeploy:"
echo "  ./setup-clusters.sh"
echo "  ./deploy.sh"

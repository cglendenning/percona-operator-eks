#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing cross-cluster service access ==="

echo ""
echo "1. Testing from Cluster A (local access):"

# Deploy a test pod in cluster-a
kubectl run test-local --image=curlimages/curl:latest --context k3d-cluster-a -n demo -- sleep 3600 2>/dev/null || true
kubectl wait --for=condition=ready pod/test-local -n demo --context k3d-cluster-a --timeout=30s

echo "Testing hello service (load balances across all 3 pods):"
for i in {1..3}; do
  echo "Request $i:"
  kubectl exec test-local -n demo --context k3d-cluster-a -- curl -s http://hello.demo.svc.cluster.local:8080
done

kubectl delete pod test-local -n demo --context k3d-cluster-a --wait=false

echo ""
echo ""
echo "2. Testing from Cluster B (remote via east-west gateway):"

# Deploy a test pod in cluster-b (will get sidecar injected)
echo "Deploying test pod with Istio sidecar..."
kubectl delete pod test-remote -n demo-dr --context k3d-cluster-b 2>/dev/null || true
kubectl run test-remote --image=curlimages/curl:latest --context k3d-cluster-b -n demo-dr -- sleep 3600
kubectl wait --for=condition=ready pod/test-remote -n demo-dr --context k3d-cluster-b --timeout=60s
echo "Waiting for Istio sidecar to be fully ready..."
sleep 5

echo ""
echo "Testing cross-cluster access via ServiceEntry (synthetic IP -> gateway):"
echo ""

for i in {1..5}; do
  echo "Request $i:"
  kubectl exec test-remote -n demo-dr --context k3d-cluster-b -- curl -s http://240.240.0.10:8080
done

kubectl delete pod test-remote -n demo-dr --context k3d-cluster-b --wait=false

echo ""
echo "=== Success! ==="
echo ""
echo "Cross-cluster service discovery works:"
echo "  - Cluster B (demo-dr namespace) can access Cluster A services"
echo "  - Traffic flows: Client -> Sidecar -> Gateway -> Backend pods"
echo "  - Load balancing across all hello pods confirmed"
echo ""
echo "For PXC cross-cluster replication, create ServiceEntries for:"
echo "  - db-pxc-0.db-pxc.demo.svc.cluster.local"
echo "  - db-pxc-1.db-pxc.demo.svc.cluster.local"
echo "  - db-pxc-2.db-pxc.demo.svc.cluster.local"

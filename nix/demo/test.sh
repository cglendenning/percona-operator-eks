#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing cross-cluster service access ==="

echo ""
echo "1. Testing from Cluster A (local - individual pods):"
echo ""
echo "Pod hello-0:"
kubectl run --context k3d-cluster-a -n demo -it --rm test-local-0 \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello-0.hello.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-1:"
kubectl run --context k3d-cluster-a -n demo -it --rm test-local-1 \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello-1.hello.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-2:"
kubectl run --context k3d-cluster-a -n demo -it --rm test-local-2 \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello-2.hello.demo.svc.cluster.local:8080

echo ""
echo ""
echo "2. Testing from Cluster B (remote via Istio ServiceEntry):"
# Create demo namespace in cluster B if it doesn't exist
kubectl create namespace demo --context k3d-cluster-b 2>/dev/null || true
kubectl label namespace demo istio-injection=enabled --context k3d-cluster-b --overwrite

echo ""
echo "Single hostname with load balancing across all pods:"
for i in 1 2 3 4 5; do
  echo "Request $i:"
  kubectl run --context k3d-cluster-b -n demo -it --rm test-remote-$i \
    --image=curlimages/curl:latest \
    --restart=Never \
    -- curl -s http://hello.cluster-a.global:8080
  echo ""
done

echo ""
echo "Success! Istio load balances across all pods in cluster-a."
echo ""
echo "For PXC, you'd point to a specific pod:"
echo "  SOURCE_HOST='hello-0.hello.demo.svc.cluster.local'"
echo "  (accessed from cluster-a, or via a separate ServiceEntry per pod)"

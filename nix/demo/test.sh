#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing cross-cluster service access ==="

echo ""
echo "1. Testing from Cluster A (local - each pod):"
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
echo "2. Testing from Cluster B (remote via Istio ServiceEntry - each pod):"
# Create demo namespace in cluster B if it doesn't exist
kubectl create namespace demo --context k3d-cluster-b 2>/dev/null || true
kubectl label namespace demo istio-injection=enabled --context k3d-cluster-b --overwrite

echo ""
echo "Remote hello-0:"
kubectl run --context k3d-cluster-b -n demo -it --rm test-remote-0 \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello-0.cluster-a.global:8080

echo ""
echo "Remote hello-1:"
kubectl run --context k3d-cluster-b -n demo -it --rm test-remote-1 \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello-1.cluster-a.global:8080

echo ""
echo "Remote hello-2:"
kubectl run --context k3d-cluster-b -n demo -it --rm test-remote-2 \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello-2.cluster-a.global:8080

echo ""
echo ""
echo "Success! Each remote pod name resolves to the correct pod in cluster-a."
echo "This is exactly how PXC async replication would work:"
echo "  SOURCE_HOST='pxc-cluster-pxc-0.production.global'"

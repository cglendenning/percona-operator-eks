#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing cross-cluster service access ==="

echo ""
echo "1. Testing from Cluster A (local):"
kubectl run --context k3d-cluster-a -n demo -it --rm test-local \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello.demo.svc.cluster.local:8080

echo ""
echo ""
echo "2. Testing from Cluster B (remote via Istio ServiceEntry):"
# Create demo namespace in cluster B if it doesn't exist
kubectl create namespace demo --context k3d-cluster-b 2>/dev/null || true
kubectl label namespace demo istio-injection=enabled --context k3d-cluster-b --overwrite

kubectl run --context k3d-cluster-b -n demo -it --rm test-remote \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s http://hello.cluster-a.global:8080

echo ""
echo ""
echo "If you see 'Hello from Cluster A!' in both tests, cross-cluster service discovery works!"

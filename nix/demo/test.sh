#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing cross-cluster service access ==="

echo ""
echo "1. Testing from Cluster A (local - individual pods):"

# Deploy a test pod without sidecar in cluster-a
kubectl run test-pod --image=curlimages/curl:latest --context k3d-cluster-a -n default -- sleep 3600 2>/dev/null || true
kubectl wait --for=condition=ready pod/test-pod -n default --context k3d-cluster-a --timeout=30s

echo ""
echo "Pod hello-0:"
kubectl exec test-pod -n default --context k3d-cluster-a -- curl -s http://hello-0.hello.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-1:"
kubectl exec test-pod -n default --context k3d-cluster-a -- curl -s http://hello-1.hello.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-2:"
kubectl exec test-pod -n default --context k3d-cluster-a -- curl -s http://hello-2.hello.demo.svc.cluster.local:8080

kubectl delete pod test-pod -n default --context k3d-cluster-a --wait=false

echo ""
echo ""
echo "2. Testing from Cluster B (remote via Istio ServiceEntry):"

# Ensure demo namespace exists with sidecar injection
kubectl create namespace demo --context k3d-cluster-b 2>/dev/null || true
kubectl label namespace demo istio-injection=enabled --context k3d-cluster-b --overwrite

# Deploy a test pod in cluster-b (will get sidecar injected)
echo "Deploying test pod with Istio sidecar..."
kubectl delete pod test-pod -n demo --context k3d-cluster-b 2>/dev/null || true
kubectl run test-pod --image=curlimages/curl:latest --context k3d-cluster-b -n demo -- sleep 3600
kubectl wait --for=condition=ready pod/test-pod -n demo --context k3d-cluster-b --timeout=60s
echo "Waiting for Istio sidecar to be fully ready..."
sleep 5

echo ""
echo "Testing remote access to individual pods:"
echo ""
echo "Pod hello-0:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://hello-0.hello.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-1:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://hello-1.hello.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-2:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://hello-2.hello.demo.svc.cluster.local:8080

kubectl delete pod test-pod -n demo --context k3d-cluster-b --wait=false

echo ""
echo "Success! Cross-cluster service discovery works via Istio ServiceEntry."
echo "Cluster B can access individual pods in Cluster A using their DNS names."
echo ""
echo "For PXC async replication, use pod-specific DNS names:"
echo "  SOURCE_HOST='pxc-cluster-pxc-0.pxc-cluster-pxc.pxc.svc.cluster.local'"

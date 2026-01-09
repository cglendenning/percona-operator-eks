#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing Simple Multi-Cluster with DNS-based ServiceEntry ==="

echo ""
echo "1. Testing from Cluster A (local access):"

# Deploy a test pod in cluster-a
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
echo "2. Testing from Cluster B (remote access via DNS aliases):"

# Ensure demo namespace exists with sidecar injection
kubectl create namespace demo --context k3d-cluster-b 2>/dev/null || true
kubectl label namespace demo istio-injection=enabled --context k3d-cluster-b --overwrite

# Deploy a test pod in cluster-b (will get sidecar injected)
echo "Deploying test pod with Istio sidecar in cluster-b..."
kubectl delete pod test-pod -n demo --context k3d-cluster-b 2>/dev/null || true
kubectl run test-pod --image=curlimages/curl:latest --context k3d-cluster-b -n demo -- sleep 3600
kubectl wait --for=condition=ready pod/test-pod -n demo --context k3d-cluster-b --timeout=60s
echo "Waiting for Istio sidecar to be fully ready..."
sleep 5

echo ""
echo "Testing cross-cluster access via DNS aliases:"
echo ""
echo "Alias 'src-hello-0' → Cluster A's hello-0 (via east-west gateway + mTLS):"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://src-hello-0.demo.svc.cluster.local:8080

echo ""
echo "Alias 'src-hello-1' → Cluster A's hello-1:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://src-hello-1.demo.svc.cluster.local:8080

echo ""
echo "Alias 'src-hello-2' → Cluster A's hello-2:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://src-hello-2.demo.svc.cluster.local:8080

kubectl delete pod test-pod -n demo --context k3d-cluster-b --wait=false

echo ""
echo "Success! Simple multi-cluster with DNS-based ServiceEntry works!"
echo ""
echo "What this demonstrates:"
echo "  ✓ NO IP addresses in configuration"
echo "  ✓ DNS-based service aliases (src-hello-X)"
echo "  ✓ mTLS encryption via east-west gateway"
echo "  ✓ Explicit ServiceEntry (easy to understand/debug)"
echo "  ✓ Shared root CA for trust"
echo ""
echo "For PXC async replication:"
echo "  - Cluster B uses: src-db-pxc-0.pxc.svc.cluster.local"
echo "  - Routes to Cluster A's db-pxc-0 via east-west gateway"
echo "  - No IP addresses, no manual endpoint updates"

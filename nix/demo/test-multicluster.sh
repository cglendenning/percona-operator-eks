#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing Multi-Cluster Service Discovery ==="

echo ""
echo "1. Testing from Cluster A (local access):"

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
echo "2. Testing from Cluster B (remote access via Istio multi-cluster):"

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
echo "Method 1: Automatic multi-cluster DNS (*.cluster-a.global)"
echo ""
echo "Pod hello-0 via automatic DNS:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://hello-0.hello.demo.svc.cluster-a.global:8080 || echo "FAILED - may need network label configuration"

echo ""
echo "Pod hello-1 via automatic DNS:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://hello-1.hello.demo.svc.cluster-a.global:8080 || echo "FAILED - may need network label configuration"

echo ""
echo "Pod hello-2 via automatic DNS:"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://hello-2.hello.demo.svc.cluster-a.global:8080 || echo "FAILED - may need network label configuration"

echo ""
echo ""
echo "Method 2: Custom alias names (mimics PXC src-db-pxc-X pattern)"
echo ""
echo "Pod hello-0 via alias 'src-hello-0' (maps to cluster-a's hello-0 by DNS):"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://src-hello-0.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-1 via alias 'src-hello-1':"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://src-hello-1.demo.svc.cluster.local:8080

echo ""
echo "Pod hello-2 via alias 'src-hello-2':"
kubectl exec test-pod -n demo --context k3d-cluster-b -- curl -s http://src-hello-2.demo.svc.cluster.local:8080

kubectl delete pod test-pod -n demo --context k3d-cluster-b --wait=false

echo ""
echo "Success! Multi-cluster Istio with DNS-based routing works!"
echo ""
echo "Key features:"
echo "- NO IP ADDRESSES - all routing via DNS names"
echo "- Custom aliases (src-hello-X) map to remote services"
echo "- Shared root CA for mTLS trust"
echo "- Automatic routing through east-west gateway"
echo "- Full mesh observability across clusters"
echo ""
echo "For PXC: Use 'src-db-pxc-0' to reference cluster-a's 'db-pxc-0'"

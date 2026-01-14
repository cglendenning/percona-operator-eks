#!/usr/bin/env bash
set -euo pipefail

echo "=== Debugging Cross-Cluster Connectivity ==="
echo ""

# Check Gateway configuration
echo "1. Gateway hosts configuration:"
kubectl get gateway cross-network-gateway -n istio-system --context=k3d-cluster-a -o jsonpath='{.spec.servers[0].hosts}' | jq .
echo ""

# Check east-west gateway service endpoints
echo "2. East-west gateway endpoints in cluster A:"
kubectl get endpoints istio-eastwestgateway -n istio-system --context=k3d-cluster-a
echo ""

# Check if gateway is receiving traffic
echo "3. East-west gateway logs (last 20 lines):"
kubectl logs -n istio-system deployment/istio-eastwestgateway --context=k3d-cluster-a --tail=20 | grep -E "HTTP|upstream|error" || echo "No relevant logs"
echo ""

# Test from test pod
echo "4. Test DNS resolution from test pod:"
kubectl exec test-pod -n wookie-dr --context=k3d-cluster-b -- nslookup helloworld.demo.svc.cluster.local || echo "DNS failed"
echo ""

# Check Envoy listener on test pod
echo "5. Envoy listeners on test pod (checking for DNS proxy):"
kubectl exec test-pod -n wookie-dr -c istio-proxy --context=k3d-cluster-b -- pilot-agent request GET listeners | grep -A 5 "envoy.filters.udp.dns_filter" || echo "DNS filter not found"
echo ""

# Check if Envoy knows about the service
echo "6. Envoy clusters for helloworld:"
kubectl exec test-pod -n wookie-dr -c istio-proxy --context=k3d-cluster-b -- pilot-agent request GET clusters | grep helloworld || echo "No helloworld cluster found"
echo ""

# Verbose curl attempt
echo "7. Verbose curl attempt:"
kubectl exec test-pod -n wookie-dr --context=k3d-cluster-b -- curl -v --max-time 5 http://helloworld.demo.svc.cluster.local:5000/hello 2>&1 || true
echo ""

# Check proxy config on test pod
echo "8. Test pod proxy metadata:"
kubectl exec test-pod -n wookie-dr -c istio-proxy --context=k3d-cluster-b -- pilot-agent request GET config_dump | grep -A 2 "ISTIO_META_DNS" || echo "DNS metadata not found"
echo ""

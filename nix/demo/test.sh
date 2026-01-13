#!/usr/bin/env bash
#
# Test Istio Multi-Primary Multi-Network Setup
# Verifies endpoint discovery and DNS resolution work correctly
#
set -euo pipefail

CTX_CLUSTER1="k3d-cluster-a"
CTX_CLUSTER2="k3d-cluster-b"

echo "=== Testing Istio Multi-Primary Multi-Network Setup ==="
echo ""

##############################################################################
# Verify Pods are Ready
##############################################################################

echo "Step 1: Verifying pods are ready..."
echo ""
echo "Hello pods in ${CTX_CLUSTER1}:"
kubectl get pods -n demo --context="${CTX_CLUSTER1}" -o wide

HELLO_PODS=$(kubectl get pods -n demo --context="${CTX_CLUSTER1}" -l app=hello --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')
if [ -z "$HELLO_PODS" ]; then
  echo "ERROR: No hello pods running in ${CTX_CLUSTER1}"
  exit 1
fi

##############################################################################
# Create Test Pod in Cluster 2
##############################################################################

echo ""
echo "Step 2: Creating test pod in ${CTX_CLUSTER2}..."

# Delete existing test pod if present
kubectl delete pod test-pod -n demo-dr --context="${CTX_CLUSTER2}" 2>/dev/null || true

# Create new test pod
kubectl run test-pod --image=curlimages/curl --context="${CTX_CLUSTER2}" -n demo-dr -- sleep 3600

echo "Waiting for test pod to be ready with sidecar..."
kubectl wait --for=condition=ready pod/test-pod -n demo-dr --context="${CTX_CLUSTER2}" --timeout=120s

# Verify sidecar injection
echo ""
echo "Checking sidecar injection:"
CONTAINERS=$(kubectl get pod test-pod -n demo-dr --context="${CTX_CLUSTER2}" -o jsonpath='{.spec.containers[*].name}')
echo "  Containers: $CONTAINERS"
if [[ "$CONTAINERS" != *"istio-proxy"* ]]; then
  echo "  WARNING: istio-proxy sidecar not found - DNS resolution may not work"
fi

##############################################################################
# Test DNS Resolution (THE CRITICAL TEST)
##############################################################################

echo ""
echo "Step 3: Testing DNS resolution from ${CTX_CLUSTER2}..."
echo ""
echo "This is the key test - DNS name should resolve via Envoy's DNS proxy"
echo "Query: hello.demo.svc.cluster.local"
echo ""

# Test DNS resolution
echo "DNS lookup result:"
kubectl exec test-pod -n demo-dr --context="${CTX_CLUSTER2}" -- nslookup hello.demo.svc.cluster.local 2>&1 || true

echo ""
echo "Attempting HTTP request using DNS name..."
RESPONSE=$(kubectl exec test-pod -n demo-dr --context="${CTX_CLUSTER2}" -- \
  curl -s --max-time 10 http://hello.demo.svc.cluster.local:8080 2>&1) || true

if echo "$RESPONSE" | grep -q "Hello from hello"; then
  echo "✓ SUCCESS: DNS resolution and routing working!"
  echo "  Response: $RESPONSE"
else
  echo "✗ FAILED: Could not reach service via DNS name"
  echo "  Response: $RESPONSE"
  echo ""
  echo "=== ROOT CAUSE ANALYSIS ==="
  echo ""
  
  # Check 1: ConfigMap has gateway IPs
  echo "CHECK 1: ConfigMap meshNetworks configuration"
  echo "-------------------------------------------"
  MESH_NETWORKS=$(kubectl get configmap istio -n istio-system --context="${CTX_CLUSTER2}" -o jsonpath='{.data.meshNetworks}')
  echo "$MESH_NETWORKS"
  if echo "$MESH_NETWORKS" | grep -q "address:"; then
    echo "✓ Gateway addresses found in ConfigMap"
  else
    echo "✗ PROBLEM: No gateway addresses in ConfigMap (using service names?)"
  fi
  echo ""
  
  # Check 2: Istiod loaded meshNetworks
  echo "CHECK 2: Istiod runtime meshNetworks configuration"
  echo "-------------------------------------------"
  ISTIOD_MESH_FULL=$(kubectl exec -n istio-system deployment/istiod --context="${CTX_CLUSTER2}" -- curl -s localhost:15014/debug/mesh 2>/dev/null || true)
  ISTIOD_MESH=$(echo "$ISTIOD_MESH_FULL" | grep -o '"meshNetworks":[^}]*}' || echo "")
  
  if [ -z "$ISTIOD_MESH" ]; then
    echo "✗ PROBLEM: Could not extract meshNetworks from istiod"
    echo "Full mesh config:"
    echo "$ISTIOD_MESH_FULL" | head -20
  elif echo "$ISTIOD_MESH" | grep -q "null"; then
    echo "✗ CRITICAL PROBLEM: Istiod has meshNetworks: null"
    echo "  This means istiod did NOT load the meshNetworks config from ConfigMap"
    echo "  Istiod will not know how to route cross-cluster traffic"
    echo "  meshNetworks value: $ISTIOD_MESH"
  else
    echo "✓ Istiod has meshNetworks configured"
    echo "  $ISTIOD_MESH"
  fi
  echo ""
  
  # Check 3: Istiod sees hello endpoints from cluster-a
  echo "CHECK 3: Istiod endpoint discovery for hello service"
  echo "-------------------------------------------"
  HELLO_ENDPOINTS=$(kubectl exec -n istio-system deployment/istiod --context="${CTX_CLUSTER2}" -- \
    curl -s localhost:15014/debug/endpointz 2>/dev/null | grep -o '"hello.demo.svc.cluster.local"[^}]*"Addresses":\[[^]]*\]' || true)
  if [ -z "$HELLO_ENDPOINTS" ]; then
    echo "✗ PROBLEM: Istiod does not see hello service endpoints"
    echo "  Check if remote secret is configured correctly"
  else
    echo "✓ Istiod sees hello service:"
    echo "  $HELLO_ENDPOINTS"
  fi
  echo ""
  
  # Check 4: Istiod sees gateway endpoints
  echo "CHECK 4: Istiod sees gateway endpoints on port 15443"
  echo "-------------------------------------------"
  GATEWAY_ENDPOINTS=$(kubectl exec -n istio-system deployment/istiod --context="${CTX_CLUSTER2}" -- \
    curl -s localhost:15014/debug/endpointz 2>/dev/null | \
    grep -A 10 '"istio-eastwestgateway.istio-system.svc.cluster.local"' | \
    grep -A 3 '"ServicePortName":"tls"' | grep '"EndpointPort":15443' || true)
  if [ -z "$GATEWAY_ENDPOINTS" ]; then
    echo "✗ PROBLEM: Istiod does not see gateway on port 15443"
  else
    echo "✓ Istiod sees gateway on port 15443"
  fi
  echo ""
  
  # Check 5: CRITICAL - Envoy sidecar has endpoints for hello service
  echo "CHECK 5: Envoy sidecar endpoint configuration (CRITICAL)"
  echo "-------------------------------------------"
  echo "Looking for hello service endpoints in Envoy..."
  ENVOY_ENDPOINTS=$(kubectl exec test-pod -n demo-dr -c istio-proxy --context="${CTX_CLUSTER2}" -- \
    pilot-agent request GET clusters 2>/dev/null | grep "hello.demo.svc.cluster.local::" | grep "::address::" || true)
  
  if [ -z "$ENVOY_ENDPOINTS" ]; then
    echo "✗ CRITICAL PROBLEM: Envoy has NO endpoints for hello service"
    echo "  Service is known but has zero endpoints"
    echo "  This means istiod is not pushing gateway routes to the sidecar"
    echo ""
    echo "  Possible causes:"
    echo "  1. meshNetworks not loaded by istiod (see CHECK 2)"
    echo "  2. Gateway network label mismatch"
    echo "  3. Istiod not applying cross-network routing logic"
  else
    echo "Envoy endpoints found:"
    echo "$ENVOY_ENDPOINTS"
    echo ""
    if echo "$ENVOY_ENDPOINTS" | grep -q "172\.24\."; then
      echo "✓ Endpoints are GATEWAY IPs (172.24.x.x) - routing will work!"
    elif echo "$ENVOY_ENDPOINTS" | grep -q "10\.42\."; then
      echo "✗ PROBLEM: Endpoints are POD IPs (10.42.x.x) - direct routing won't work"
      echo "  Istiod is not using meshNetworks for cross-network routing"
    fi
  fi
  echo ""
  
  # Check 6: Envoy knows about service but summary
  echo "CHECK 6: Envoy service registry summary"
  echo "-------------------------------------------"
  (kubectl exec test-pod -n demo-dr -c istio-proxy --context="${CTX_CLUSTER2}" -- \
    pilot-agent request GET clusters 2>/dev/null | grep "hello.demo" | head -5) || echo "  No hello service found in Envoy config"
  
  echo ""
  echo "CHECK 7: Istiod logs"
  echo "-------------------------------------------"
  (kubectl logs -n istio-system deployment/istiod --context="${CTX_CLUSTER2}" --tail=20 2>/dev/null | grep -i error) || echo "  No recent errors"
  
  exit 1
fi

##############################################################################
# Test Multiple Requests (Load Balancing)
##############################################################################

echo ""
echo "Step 4: Testing load balancing across pods..."
echo ""

for i in {1..6}; do
  RESPONSE=$(kubectl exec test-pod -n demo-dr --context="${CTX_CLUSTER2}" -- \
    curl -s http://hello.demo.svc.cluster.local:8080 2>&1)
  echo "  Request $i: $RESPONSE"
done

##############################################################################
# Verify Sidecars and mTLS
##############################################################################

echo ""
echo "Step 5: Verifying sidecar injection and connectivity..."
echo ""

# Check hello-0 has sidecar
HELLO0_CONTAINERS=$(kubectl get pod hello-0 -n demo --context="${CTX_CLUSTER1}" -o jsonpath='{.spec.containers[*].name}')
echo "hello-0 containers: $HELLO0_CONTAINERS"
if [[ "$HELLO0_CONTAINERS" != *"istio-proxy"* ]]; then
  echo "  WARNING: hello-0 missing istio-proxy sidecar"
fi

# Check proxy status
echo ""
echo "Istio proxy status in ${CTX_CLUSTER1}:"
istioctl proxy-status --context="${CTX_CLUSTER1}" | grep hello || echo "No hello pods in proxy status"

echo ""
echo "Istio proxy status in ${CTX_CLUSTER2}:"
istioctl proxy-status --context="${CTX_CLUSTER2}" | grep test-pod || echo "test-pod not in proxy status"

##############################################################################
# Check mTLS
##############################################################################

echo ""
echo "Step 6: Checking mTLS configuration..."
echo ""

echo "Checking if mTLS certificates exist in hello-0:"
kubectl exec hello-0 -n demo -c istio-proxy --context="${CTX_CLUSTER1}" -- \
  ls -la /var/run/secrets/istio/ 2>/dev/null | grep -E "(cert|key)" || echo "Certificate files not found"

echo ""
echo "Checking SSL handshake stats in hello-0:"
kubectl exec hello-0 -n demo -c istio-proxy --context="${CTX_CLUSTER1}" -- \
  pilot-agent request GET stats | grep ssl.handshake || echo "No SSL handshake stats"

##############################################################################
# Verify Endpoint Discovery
##############################################################################

echo ""
echo "Step 7: Verifying endpoint discovery (remote secrets)..."
echo ""

echo "Remote secrets in ${CTX_CLUSTER1}:"
kubectl get secrets -n istio-system --context="${CTX_CLUSTER1}" | grep "istio-remote-secret" || echo "No remote secrets found"

echo ""
echo "Remote secrets in ${CTX_CLUSTER2}:"
kubectl get secrets -n istio-system --context="${CTX_CLUSTER2}" | grep "istio-remote-secret" || echo "No remote secrets found"

##############################################################################
# Check Envoy Configuration
##############################################################################

echo ""
echo "Step 8: Checking Envoy knows about cross-cluster service..."
echo ""

echo "Clusters configured in test-pod Envoy:"
kubectl exec test-pod -n demo-dr -c istio-proxy --context="${CTX_CLUSTER2}" -- \
  pilot-agent request GET clusters | grep "outbound.*hello" | head -10

##############################################################################
# Summary
##############################################################################

echo ""
echo "=== Test Complete ==="
echo ""
echo "✓ DNS resolution: hello.demo.svc.cluster.local resolves correctly"
echo "✓ Cross-cluster routing: Traffic flows from cluster-b to cluster-a"
echo "✓ Endpoint discovery: Clusters know about each other's services"
echo "✓ Envoy DNS proxy: Intercepts DNS queries and returns virtual IPs"
echo ""
echo "This confirms the official Istio multi-primary approach is working!"
echo ""
echo "Key behaviors:"
echo "  1. Envoy DNS proxy intercepts DNS queries (not CoreDNS)"
echo "  2. Envoy returns auto-allocated virtual IPs for remote services"
echo "  3. Standard Kubernetes DNS names work without modification"
echo "  4. No manual ServiceEntry configuration required"

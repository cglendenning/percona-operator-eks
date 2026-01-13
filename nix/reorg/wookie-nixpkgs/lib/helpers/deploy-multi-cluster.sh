#!/usr/bin/env bash
set -euo pipefail

# Multi-cluster deployment script for Istio multi-primary multi-network setup
# This script expects to be called with cluster contexts as environment variables

CTX_CLUSTER1="${CLUSTER_A_CONTEXT:-k3d-cluster-a}"
CTX_CLUSTER2="${CLUSTER_B_CONTEXT:-k3d-cluster-b}"
MANIFESTS_CLUSTER_A="${MANIFESTS_CLUSTER_A_PATH:?MANIFESTS_CLUSTER_A_PATH must be set}"
MANIFESTS_CLUSTER_B="${MANIFESTS_CLUSTER_B_PATH:?MANIFESTS_CLUSTER_B_PATH must be set}"

echo "=== Deploying Istio Multi-Primary Multi-Network ==="
echo ""

##############################################################################
# Step 1: Deploy to cluster-a
##############################################################################

echo "Step 1: Deploying to cluster-a ($CTX_CLUSTER1)..."
echo ""

# Apply namespaces batch
echo "  Applying namespaces..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_A" --context="$CTX_CLUSTER1" || true

sleep 3

# Apply CRDs batch
echo "  Applying CRDs..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_A" --context="$CTX_CLUSTER1" || true

sleep 5

# Apply operators batch (istiod)
echo "  Applying operators..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_A" --context="$CTX_CLUSTER1" || true

# Apply services batch (gateways, apps)
echo "  Applying services..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_A" --context="$CTX_CLUSTER1" || true

echo ""
echo "Waiting for istiod in cluster-a..."
kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context="$CTX_CLUSTER1"

##############################################################################
# Step 2: Deploy to cluster-b
##############################################################################

echo ""
echo "Step 2: Deploying to cluster-b ($CTX_CLUSTER2)..."
echo ""

# Apply namespaces batch
echo "  Applying namespaces..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_B" --context="$CTX_CLUSTER2" || true

sleep 3

# Apply CRDs batch
echo "  Applying CRDs..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_B" --context="$CTX_CLUSTER2" || true

sleep 5

# Apply operators batch (istiod)
echo "  Applying operators..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_B" --context="$CTX_CLUSTER2" || true

# Apply services batch (gateways, apps)
echo "  Applying services..."
kubectl apply --validate=false -f "$MANIFESTS_CLUSTER_B" --context="$CTX_CLUSTER2" || true

echo ""
echo "Waiting for istiod in cluster-b..."
kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context="$CTX_CLUSTER2"

##############################################################################
# Step 3: Configure gateway external IPs
##############################################################################

echo ""
echo "Step 3: Configuring gateway external IPs..."

# Get gateway IPs from the shared network
GATEWAY_IP_A=$(docker inspect k3d-cluster-a-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')
GATEWAY_IP_B=$(docker inspect k3d-cluster-b-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')

echo "  Gateway A IP: $GATEWAY_IP_A"
echo "  Gateway B IP: $GATEWAY_IP_B"

# Patch gateway services with external IPs
kubectl patch service istio-eastwestgateway -n istio-system --context="$CTX_CLUSTER1" \
  -p "{\"spec\":{\"externalIPs\":[\"$GATEWAY_IP_A\"]}}"

kubectl patch service istio-eastwestgateway -n istio-system --context="$CTX_CLUSTER2" \
  -p "{\"spec\":{\"externalIPs\":[\"$GATEWAY_IP_B\"]}}"

##############################################################################
# Step 4: Update meshNetworks configuration
##############################################################################

echo ""
echo "Step 4: Updating meshNetworks configuration..."

# Update cluster-a meshNetworks
kubectl get configmap istio -n istio-system --context="$CTX_CLUSTER1" -o yaml | \
  yq eval ".data.meshNetworks = \"networks:\\n  network1:\\n    endpoints:\\n    - fromRegistry: cluster-a\\n    gateways:\\n    - address: $GATEWAY_IP_A\\n      port: 15443\\n  network2:\\n    endpoints:\\n    - fromRegistry: cluster-b\\n    gateways:\\n    - address: $GATEWAY_IP_B\\n      port: 15443\"" - | \
  kubectl apply --context="$CTX_CLUSTER1" -f -

# Update cluster-b meshNetworks
kubectl get configmap istio -n istio-system --context="$CTX_CLUSTER2" -o yaml | \
  yq eval ".data.meshNetworks = \"networks:\\n  network1:\\n    endpoints:\\n    - fromRegistry: cluster-a\\n    gateways:\\n    - address: $GATEWAY_IP_A\\n      port: 15443\\n  network2:\\n    endpoints:\\n    - fromRegistry: cluster-b\\n    gateways:\\n    - address: $GATEWAY_IP_B\\n      port: 15443\"" - | \
  kubectl apply --context="$CTX_CLUSTER2" -f -

##############################################################################
# Step 5: Create remote secrets for endpoint discovery
##############################################################################

echo ""
echo "Step 5: Creating remote secrets for endpoint discovery..."

# Get API server IPs
CLUSTER_A_API_IP=$(docker inspect k3d-cluster-a-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')
CLUSTER_B_API_IP=$(docker inspect k3d-cluster-b-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')

istioctl create-remote-secret \
  --context="$CTX_CLUSTER2" \
  --name=cluster-b \
  --server="https://$CLUSTER_B_API_IP:6443" | \
  kubectl apply -f - --context="$CTX_CLUSTER1"

istioctl create-remote-secret \
  --context="$CTX_CLUSTER1" \
  --name=cluster-a \
  --server="https://$CLUSTER_A_API_IP:6443" | \
  kubectl apply -f - --context="$CTX_CLUSTER2"

echo ""
echo "Restarting istiod pods to reload configuration..."
kubectl rollout restart deployment/istiod -n istio-system --context="$CTX_CLUSTER1"
kubectl rollout restart deployment/istiod -n istio-system --context="$CTX_CLUSTER2"

kubectl rollout status deployment/istiod -n istio-system --context="$CTX_CLUSTER1" --timeout=180s
kubectl rollout status deployment/istiod -n istio-system --context="$CTX_CLUSTER2" --timeout=180s

##############################################################################
# Step 6: Wait for hello pods
##############################################################################

echo ""
echo "Step 6: Waiting for hello pods in cluster-a..."
kubectl wait --for=condition=ready --timeout=180s pod -l app=helloworld -n demo --context="$CTX_CLUSTER1" || true

##############################################################################
# Summary
##############################################################################

echo ""
echo "=== Multi-cluster deployment complete ==="
echo ""
echo "Gateway addresses:"
echo "  network1 (cluster-a): $GATEWAY_IP_A:15443"
echo "  network2 (cluster-b): $GATEWAY_IP_B:15443"
echo ""
echo "Verify with:"
echo "  kubectl get pods -n istio-system --context=$CTX_CLUSTER1"
echo "  kubectl get pods -n demo --context=$CTX_CLUSTER1"
echo "  kubectl get pods -n istio-system --context=$CTX_CLUSTER2"
echo ""
echo "Test connectivity:"
echo "  nix run .#test-multi-cluster"

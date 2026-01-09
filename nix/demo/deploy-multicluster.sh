#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Full Multi-Cluster Istio Setup ==="

# Step 1: Setup shared CA certificates
echo ""
echo "Step 1: Generating shared root CA..."
./setup-certs.sh

# Step 2: Build Istio manifests
echo ""
echo "Step 2: Building Istio manifests..."
cd ..
nix build .#istio-all
cd demo

# Step 3: Deploy Istio to Cluster A with multi-cluster config
echo ""
echo "Step 3: Deploying Istio to Cluster A (cluster-a)..."
kubectl config use-context k3d-cluster-a

# Apply base Istio
kubectl apply -f ../result/manifest.yaml --validate=false

# Configure istiod for multi-cluster
kubectl patch deployment istiod -n istio-system --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "CLUSTER_ID",
      "value": "cluster-a"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "EXTERNAL_ISTIOD",
      "value": "false"
    }
  }
]'

kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster A"

# Step 4: Deploy east-west gateway to Cluster A
echo ""
echo "Step 4: Deploying east-west gateway to Cluster A..."
kubectl apply -f eastwest-gateway.yaml --context k3d-cluster-a
kubectl wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system --context k3d-cluster-a

# Get east-west gateway IP/endpoint for cluster-a
CLUSTER_A_EW_IP=$(kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -z "$CLUSTER_A_EW_IP" ]; then
  # k3d uses hostIP for LoadBalancer
  CLUSTER_A_EW_IP=$(kubectl get nodes --context k3d-cluster-a -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
fi
echo "Cluster A east-west gateway IP: $CLUSTER_A_EW_IP"

# Step 5: Deploy Istio to Cluster B
echo ""
echo "Step 5: Deploying Istio to Cluster B (cluster-b)..."
kubectl config use-context k3d-cluster-b
kubectl apply -f ../result/manifest.yaml --validate=false

# Configure istiod for multi-cluster
kubectl patch deployment istiod -n istio-system --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "CLUSTER_ID",
      "value": "cluster-b"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "EXTERNAL_ISTIOD",
      "value": "false"
    }
  }
]'

kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster B"

# Step 6: Deploy east-west gateway to Cluster B
echo ""
echo "Step 6: Deploying east-west gateway to Cluster B..."
kubectl apply -f eastwest-gateway.yaml --context k3d-cluster-b
kubectl wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system --context k3d-cluster-b

# Step 7: Enable endpoint discovery via remote secrets
echo ""
echo "Step 7: Configuring endpoint discovery between clusters..."

# Create remote secret for cluster-a to access cluster-b
kubectl create secret generic cluster-b --context k3d-cluster-a -n istio-system \
  --from-literal=kubeconfig="$(kubectl config view --flatten --minify --context=k3d-cluster-b)" \
  --dry-run=client -o yaml | kubectl apply --context k3d-cluster-a -f -

# Create remote secret for cluster-b to access cluster-a  
kubectl create secret generic cluster-a --context k3d-cluster-b -n istio-system \
  --from-literal=kubeconfig="$(kubectl config view --flatten --minify --context=k3d-cluster-a)" \
  --dry-run=client -o yaml | kubectl apply --context k3d-cluster-b -f -

echo "Remote secrets configured for service discovery"

# Step 8: Deploy hello service to Cluster A
echo ""
echo "Step 8: Deploying hello service to Cluster A..."
kubectl config use-context k3d-cluster-a
kubectl delete svc hello -n demo 2>/dev/null || true
kubectl apply -f hello-service.yaml

echo "Waiting for hello pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=60s

echo ""
echo "Hello pods in Cluster A:"
kubectl get pods -n demo -o wide --context k3d-cluster-a

# Step 9: Label clusters for multi-cluster DNS
echo ""
echo "Step 9: Configuring multi-cluster DNS..."

# Label istio-system namespace with cluster name (enables .cluster-a.global DNS)
kubectl label namespace istio-system topology.istio.io/network=network1 --context k3d-cluster-a --overwrite
kubectl label namespace istio-system topology.istio.io/network=network1 --context k3d-cluster-b --overwrite

kubectl annotate namespace demo topology.istio.io/controlPlaneClusters=cluster-a --context k3d-cluster-a --overwrite
kubectl annotate namespace demo topology.istio.io/controlPlaneClusters=cluster-b --context k3d-cluster-b --overwrite

# Step 10: Deploy ServiceEntry aliases in cluster-b
echo ""
echo "Step 10: Creating service aliases in cluster-b..."
echo "This enables: src-hello-0 -> cluster-a's hello-0 (by DNS name, no IPs)"
kubectl apply -f hello-aliases.yaml --context k3d-cluster-b

echo ""
echo "Multi-cluster Istio deployment complete!"
echo ""
echo "Cluster A east-west gateway: $CLUSTER_A_EW_IP:15443"
echo ""
echo "Services in cluster-a are accessible from cluster-b via:"
echo "  1. Auto multi-cluster DNS: hello-X.hello.demo.svc.cluster-a.global"
echo "  2. Custom aliases: src-hello-X.demo.svc.cluster.local"
echo ""
echo "Both use DNS names only - no IP addresses!"
echo "Test with: ./test-multicluster.sh"

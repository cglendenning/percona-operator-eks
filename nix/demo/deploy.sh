#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Istio and demo services ==="

# Deploy Istio to Cluster A
echo ""
echo "Deploying Istio to Cluster A..."
kubectl config use-context k3d-cluster-a
kubectl apply -f ../result/manifest.yaml --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster A"

# Deploy Istio to Cluster B
echo ""
echo "Deploying Istio to Cluster B..."
kubectl config use-context k3d-cluster-b
kubectl apply -f ../result/manifest.yaml --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster B"

# Deploy hello service to Cluster A
echo ""
echo "Deploying hello service to Cluster A..."
kubectl config use-context k3d-cluster-a
kubectl apply -f hello-service.yaml

# Wait for sidecar injection and pods ready
echo "Waiting for hello pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=60s

echo ""
echo "Getting Cluster A node IPs (needed for ServiceEntry)..."
kubectl get nodes -o wide --context k3d-cluster-a

echo ""
echo "Update the 'endpoints' addresses in flake.nix with the IPs above, then:"
echo "  cd .."
echo "  nix build .#hello-remote"
echo "  kubectl apply -f result/manifest.yaml --context k3d-cluster-b"

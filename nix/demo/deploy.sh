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

# Delete existing service if it exists (can't change clusterIP)
kubectl delete svc hello -n demo 2>/dev/null || true

kubectl apply -f hello-service.yaml

# Wait for sidecar injection and pods ready
echo "Waiting for hello pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=60s

echo ""
echo "Hello pods in Cluster A:"
kubectl get pods -n demo -o wide --context k3d-cluster-a

echo ""
echo "Hello services (like PXC pod services):"
kubectl get svc -n demo --context k3d-cluster-a

# Create demo namespace in Cluster B
echo ""
echo "Creating demo namespace in Cluster B..."
kubectl config use-context k3d-cluster-b
kubectl create namespace demo 2>/dev/null || echo "Namespace demo already exists"
kubectl label namespace demo istio-injection=enabled --overwrite

echo ""
echo "ServiceEntry uses DNS names (no IP updates needed):"
echo "  hello-0.hello.demo.svc.cluster.local"
echo "  hello-1.hello.demo.svc.cluster.local"
echo "  hello-2.hello.demo.svc.cluster.local"

echo ""
echo "Next steps:"
echo "  cd .."
echo "  nix build .#hello-remote"
echo "  kubectl apply -f result/manifest.yaml --context k3d-cluster-b"
echo "  cd demo"
echo "  ./test.sh"
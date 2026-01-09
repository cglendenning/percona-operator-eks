#!/usr/bin/env bash
set -euo pipefail

echo "=== Setting up two k3d clusters for cross-cluster demo ==="

# Cluster A (source)
echo "Creating Cluster A..."
k3d cluster create cluster-a \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:*"

# Cluster B (target)
echo "Creating Cluster B..."
k3d cluster create cluster-b \
  --servers 1 \
  --agents 2 \
  --port "9080:80@loadbalancer" \
  --port "9443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:*"

echo ""
echo "Clusters created:"
k3d cluster list

echo ""
echo "Kubeconfig contexts:"
kubectl config get-contexts | grep k3d

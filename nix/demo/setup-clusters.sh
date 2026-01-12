#!/usr/bin/env bash
set -euo pipefail

echo "=== Setting up two k3d clusters for cross-cluster demo ==="

# Create dedicated shared Docker network with specific subnet
echo "Creating dedicated shared Docker network..."
docker network create k3d-multicluster --subnet=172.24.0.0/16 2>/dev/null || {
  echo "Network exists, recreating..."
  docker network rm k3d-multicluster 2>/dev/null || true
  docker network create k3d-multicluster --subnet=172.24.0.0/16
}

echo "Network created: 172.24.0.0/16"
echo ""

# When using --network, k3d connects server nodes to that network
# IPs are assigned sequentially starting from .2 (after gateway at .1)
# Each cluster uses approximately 5-6 IPs (server, agents, loadbalancer, tools)
# So cluster-a will be around .2-.7 and cluster-b around .8-.13

echo "Creating Cluster A on shared network..."
k3d cluster create cluster-a \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --network k3d-multicluster \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--tls-san=172.24.0.2@server:0" \
  --k3s-arg "--tls-san=172.24.0.3@server:0" \
  --k3s-arg "--tls-san=172.24.0.4@server:0" \
  --k3s-arg "--tls-san=172.24.0.5@server:0" \
  --k3s-arg "--tls-san=172.24.0.6@server:0" \
  --k3s-arg "--tls-san=172.24.0.7@server:0" \
  --k3s-arg "--tls-san=172.24.0.8@server:0"

echo ""
echo "Creating Cluster B on shared network..."
k3d cluster create cluster-b \
  --servers 1 \
  --agents 2 \
  --port "9080:80@loadbalancer" \
  --port "9443:443@loadbalancer" \
  --network k3d-multicluster \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--tls-san=172.24.0.2@server:0" \
  --k3s-arg "--tls-san=172.24.0.3@server:0" \
  --k3s-arg "--tls-san=172.24.0.4@server:0" \
  --k3s-arg "--tls-san=172.24.0.5@server:0" \
  --k3s-arg "--tls-san=172.24.0.6@server:0" \
  --k3s-arg "--tls-san=172.24.0.7@server:0" \
  --k3s-arg "--tls-san=172.24.0.8@server:0" \
  --k3s-arg "--tls-san=172.24.0.9@server:0" \
  --k3s-arg "--tls-san=172.24.0.10@server:0" \
  --k3s-arg "--tls-san=172.24.0.11@server:0" \
  --k3s-arg "--tls-san=172.24.0.12@server:0" \
  --k3s-arg "--tls-san=172.24.0.13@server:0" \
  --k3s-arg "--tls-san=172.24.0.14@server:0" \
  --k3s-arg "--tls-san=172.24.0.15@server:0"

echo ""
echo "Clusters created on shared network:"
k3d cluster list

echo ""
echo "Verifying API server IPs on k3d-multicluster network..."
CLUSTER_A_IP=$(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{if .NetworkID}}{{.IPAddress}} {{end}}{{end}}' | awk '{print $1}')
CLUSTER_B_IP=$(docker inspect k3d-cluster-b-server-0 -f '{{range .NetworkSettings.Networks}}{{if .NetworkID}}{{.IPAddress}} {{end}}{{end}}' | awk '{print $1}')

echo "Cluster A server IP: ${CLUSTER_A_IP}"
echo "Cluster B server IP: ${CLUSTER_B_IP}"

echo ""
echo "All nodes on k3d-multicluster network:"
docker network inspect k3d-multicluster -f '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{println}}{{end}}' | grep k3d-cluster

echo ""
echo "Kubeconfig contexts:"
kubectl config get-contexts | grep k3d

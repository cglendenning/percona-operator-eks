#!/usr/bin/env bash
set -euo pipefail

echo "=== Setting up two k3d clusters for cross-cluster demo ==="

# Create shared Docker network first with specific subnet
echo "Creating shared Docker network..."
docker network create k3d-shared --subnet=172.23.0.0/16 2>/dev/null || echo "Network k3d-shared already exists"

# Get network subnet to determine IP range for TLS SANs
NETWORK_SUBNET=$(docker network inspect k3d-shared -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
echo "Shared network subnet: ${NETWORK_SUBNET}"

# Create clusters with TLS SANs for IPs they'll get on shared network
# Docker typically assigns IPs sequentially starting from .2
# We'll add SANs for the likely range to be safe

echo ""
echo "Creating Cluster A with TLS SANs for shared network..."
k3d cluster create cluster-a \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--tls-san=172.23.0.2@server:0" \
  --k3s-arg "--tls-san=172.23.0.3@server:0" \
  --k3s-arg "--tls-san=172.23.0.4@server:0" \
  --k3s-arg "--tls-san=172.23.0.5@server:0" \
  --k3s-arg "--tls-san=172.23.0.6@server:0" \
  --k3s-arg "--tls-san=172.23.0.7@server:0" \
  --k3s-arg "--tls-san=172.23.0.8@server:0"

echo ""
echo "Creating Cluster B with TLS SANs for shared network..."
k3d cluster create cluster-b \
  --servers 1 \
  --agents 2 \
  --port "9080:80@loadbalancer" \
  --port "9443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--tls-san=172.23.0.2@server:0" \
  --k3s-arg "--tls-san=172.23.0.3@server:0" \
  --k3s-arg "--tls-san=172.23.0.4@server:0" \
  --k3s-arg "--tls-san=172.23.0.5@server:0" \
  --k3s-arg "--tls-san=172.23.0.6@server:0" \
  --k3s-arg "--tls-san=172.23.0.7@server:0" \
  --k3s-arg "--tls-san=172.23.0.8@server:0"

# Connect clusters to shared network
echo ""
echo "Connecting cluster nodes to shared network..."
for node in $(docker ps --format '{{.Names}}' | grep -E 'k3d-cluster-[ab]'); do
  docker network connect k3d-shared $node 2>/dev/null || echo "$node already connected"
done

echo ""
echo "Clusters created and connected:"
k3d cluster list

echo ""
echo "Verifying API server IPs on shared network..."
echo "Cluster A server IP: $(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-shared -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')"
echo "Cluster B server IP: $(docker inspect k3d-cluster-b-server-0 -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-shared -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')"

echo ""
echo "Kubeconfig contexts:"
kubectl config get-contexts | grep k3d

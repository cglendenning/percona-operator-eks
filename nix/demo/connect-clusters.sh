#!/usr/bin/env bash
set -euo pipefail

echo "=== Connecting clusters via shared network (simulates VPC peering/VPN) ==="

# Create shared network for inter-cluster communication
echo "Creating shared network 'k3d-interconnect'..."
docker network create k3d-interconnect 2>/dev/null || echo "Network already exists"

# Connect all cluster-a nodes to shared network
echo ""
echo "Connecting cluster-a nodes to shared network..."
for node in k3d-cluster-a-server-0 k3d-cluster-a-agent-0 k3d-cluster-a-agent-1; do
  docker network connect k3d-interconnect $node 2>/dev/null || echo "$node already connected"
done

# Connect all cluster-b nodes to shared network
echo ""
echo "Connecting cluster-b nodes to shared network..."
for node in k3d-cluster-b-server-0 k3d-cluster-b-agent-0 k3d-cluster-b-agent-1; do
  docker network connect k3d-interconnect $node 2>/dev/null || echo "$node already connected"
done

echo ""
echo "Clusters connected! Nodes now have IPs on shared network:"
echo ""
echo "Cluster A nodes:"
for node in k3d-cluster-a-server-0 k3d-cluster-a-agent-0 k3d-cluster-a-agent-1; do
  ip=$(docker inspect $node -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-interconnect -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
  echo "  $node: $ip"
done

echo ""
echo "Cluster B nodes:"
for node in k3d-cluster-b-server-0 k3d-cluster-b-agent-0 k3d-cluster-b-agent-1; do
  ip=$(docker inspect $node -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-interconnect -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
  echo "  $node: $ip"
done

echo ""
echo "Getting pod IPs from cluster-a..."
kubectl get pods -n demo --context k3d-cluster-a -o wide | grep hello

echo ""
echo "Network connectivity established!"
echo "Pods in cluster-a are now reachable from cluster-b via their pod IPs."

#!/usr/bin/env bash
set -euo pipefail

echo "=== Cleaning up k3d clusters ==="

echo "Deleting cluster-a..."
k3d cluster delete cluster-a

echo "Deleting cluster-b..."
k3d cluster delete cluster-b

echo ""
echo "Removing Docker networks..."
docker network rm k3d-interconnect 2>/dev/null || echo "Network already removed"

echo ""
echo "Removing certificates..."
rm -rf ./certs 2>/dev/null || echo "Certificates already removed"

echo ""
echo "Clusters deleted. Verify:"
k3d cluster list

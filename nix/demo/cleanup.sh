#!/usr/bin/env bash
set -euo pipefail

echo "=== Cleaning up k3d clusters ==="

echo "Deleting cluster-a..."
k3d cluster delete cluster-a 2>/dev/null || echo "Cluster-a already deleted"

echo "Deleting cluster-b..."
k3d cluster delete cluster-b 2>/dev/null || echo "Cluster-b already deleted"

echo ""
echo "Removing shared Docker network..."
docker network rm k3d-shared 2>/dev/null || echo "Network already removed"

echo ""
echo "Cleanup complete. Verify:"
k3d cluster list

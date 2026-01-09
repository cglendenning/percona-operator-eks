#!/usr/bin/env bash
set -euo pipefail

echo "=== Cleaning up k3d clusters ==="

echo "Deleting cluster-a..."
k3d cluster delete cluster-a

echo "Deleting cluster-b..."
k3d cluster delete cluster-b

echo ""
echo "Clusters deleted. Verify:"
k3d cluster list

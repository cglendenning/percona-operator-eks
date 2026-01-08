#!/usr/bin/env bash
#
# Quickstart script for k3d + Istio Nix flake
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== k3d + Istio Nix Flake Quickstart ==="
echo ""

# Check if Nix is installed
if ! command -v nix &> /dev/null; then
    echo "ERROR: Nix is not installed"
    echo "Install from: https://nixos.org/download.html"
    exit 1
fi

# Check if flakes are enabled
if ! nix flake --help &> /dev/null; then
    echo "ERROR: Nix flakes are not enabled"
    echo "Add to ~/.config/nix/nix.conf:"
    echo "  experimental-features = nix-command flakes"
    exit 1
fi

echo "Step 1: Show flake outputs"
nix flake show
echo ""

echo "Step 2: Check flake validity"
nix flake check
echo ""

echo "Step 3: Build all manifests"
nix build
echo ""

echo "Step 4: Create k3d cluster"
./result/bin/k3d-create
echo ""

echo "Step 5: Deploy Istio"
kubectl apply -f result/manifest.yaml
echo ""

echo "Step 6: Wait for Istio to be ready"
kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system
echo ""

echo "=== Deployment Complete ==="
echo ""
echo "Cluster status:"
./result/bin/k3d-status
echo ""
echo "Istio version:"
istioctl version
echo ""
echo "Next steps:"
echo "  - Deploy your applications with Istio sidecar injection"
echo "  - Configure ingress gateway"
echo "  - Set up observability (Kiali, Jaeger, Grafana)"
echo ""
echo "Cleanup:"
echo "  ./result/bin/k3d-delete"

#!/bin/bash
#
# Render Kubernetes manifests using Nix
#
# Usage:
#   ./render.sh                    # Render all manifests
#   ./render.sh --help             # Show options

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NIX_FLAGS="--extra-experimental-features nix-command --extra-experimental-features flakes"

case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo ""
        echo "Renders Kubernetes manifests for DR Dashboard."
        echo "Edit flake.nix to change configuration (namespace, tag, ingress host)."
        echo ""
        echo "Output:"
        echo "  namespace/manifest.yaml  - Namespace resource"
        echo "  webui/manifest.yaml      - Deployment, Service, Ingress"
        exit 0
        ;;
esac

echo "Building DR Dashboard manifests..."

# Build namespace
echo "  Building namespace..."
nix $NIX_FLAGS build --impure .#namespace --out-link result-namespace
mkdir -p namespace
rm -f namespace/manifest.yaml
cp result-namespace/manifest.yaml namespace/manifest.yaml
chmod 644 namespace/manifest.yaml
rm -f result-namespace

# Build webui
echo "  Building webui..."
nix $NIX_FLAGS build --impure .#webui --out-link result-webui
mkdir -p webui
rm -f webui/manifest.yaml
cp result-webui/manifest.yaml webui/manifest.yaml
chmod 644 webui/manifest.yaml
rm -f result-webui

echo ""
echo "Generated:"
echo "  namespace/manifest.yaml"
echo "  webui/manifest.yaml"

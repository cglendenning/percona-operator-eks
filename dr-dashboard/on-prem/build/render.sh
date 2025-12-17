#!/bin/bash
#
# Render Kubernetes manifests using Nix
#
# Usage:
#   ./render.sh                    # Render with default config
#   ./render.sh --help             # Show options

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_FILE="manifest.yaml"
NIX_FLAGS="--extra-experimental-features nix-command --extra-experimental-features flakes"

case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo ""
        echo "Renders Kubernetes manifests for DR Dashboard."
        echo "Edit flake.nix to change configuration (registry, tag, ingress host)."
        echo ""
        echo "Output: manifests.yaml"
        exit 0
        ;;
esac

echo "Building DR Dashboard manifests..."
nix $NIX_FLAGS build --impure --out-link result

rm -f "$OUTPUT_FILE"
cp result/manifest.yaml "$OUTPUT_FILE"
chmod 644 "$OUTPUT_FILE"
rm -f result

echo "Generated: $OUTPUT_FILE"

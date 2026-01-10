#!/usr/bin/env bash
# Fetch SHA256 hashes for Istio Helm charts

set -euo pipefail

ISTIO_VERSION="1.24.2"
ISTIO_REPO="https://istio-release.storage.googleapis.com/charts"

echo "Fetching Istio chart hashes for version ${ISTIO_VERSION}..."
echo ""

charts=("base" "istiod" "gateway")

for chart in "${charts[@]}"; do
    echo "Fetching $chart..."
    URL="${ISTIO_REPO}/${chart}-${ISTIO_VERSION}.tgz"
    
    # Use nix-prefetch-url to get the hash
    HASH=$(nix-prefetch-url "$URL" 2>&1 | tail -n1)
    
    echo "  $chart: $HASH"
    echo ""
done

echo "Update pkgs/charts/charts.nix with these hashes:"
echo ""
echo "istio-base.\"1_24_2\".chartHash = \"<hash-for-base>\";"
echo "istiod.\"1_24_2\".chartHash = \"<hash-for-istiod>\";"
echo "istio-gateway.\"1_24_2\".chartHash = \"<hash-for-gateway>\";"

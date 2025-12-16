#!/bin/bash
#
# Build Docker image for DR Dashboard (EKS)
#
# Usage:
#   ./build.sh              # Build image with 'latest' tag
#   ./build.sh v1.0.0       # Build image with specific tag
#
# Environment variables:
#   REGISTRY   - Container registry (default: none, local only)
#   IMAGE_NAME - Image name (default: dr-dashboard-eks)

set -e

TAG="${1:-latest}"
REGISTRY="${REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-dr-dashboard-eks}"

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DR_DASHBOARD_DIR/.." && pwd)"

echo "Building DR Dashboard (EKS)"
echo "  Tag: $TAG"
echo "  Repo root: $REPO_ROOT"

# Verify required files exist
if [ ! -f "$REPO_ROOT/testing/eks/disaster_scenarios/disaster_scenarios.json" ]; then
    echo "ERROR: Disaster scenarios not found"
    exit 1
fi

if [ ! -d "$DR_DASHBOARD_DIR/recovery_processes/eks" ]; then
    echo "ERROR: Recovery processes not found"
    exit 1
fi

# Build image name
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"
else
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"
fi

# Check Docker is available
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running"
    echo "  On WSL: sudo service docker start"
    echo "  On macOS: Start Docker Desktop"
    exit 1
fi

# Build the image
echo "Building: $FULL_IMAGE"
docker build \
    -f "$DR_DASHBOARD_DIR/Dockerfile" \
    --build-arg ENVIRONMENT=eks \
    -t "$FULL_IMAGE" \
    "$REPO_ROOT"

echo ""
echo "Build complete: $FULL_IMAGE"
echo ""
echo "Run locally:"
echo "  docker run -p 8080:8080 $FULL_IMAGE"

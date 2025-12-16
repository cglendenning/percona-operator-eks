#!/bin/bash
#
# Build Docker image for DR Dashboard (On-Prem)
#
# Usage:
#   ./build.sh              # Build image with 'latest' tag
#   ./build.sh v1.0.0       # Build image with specific tag
#
# Environment variables:
#   REGISTRY   - Container registry (default: none, local only)
#   IMAGE_NAME - Image name (default: dr-dashboard-on-prem)

set -e

TAG="${1:-latest}"
REGISTRY="${REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-dr-dashboard-on-prem}"

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DR_DASHBOARD_DIR/.." && pwd)"

echo "Building DR Dashboard (On-Prem)"
echo "  Tag: $TAG"
echo "  Repo root: $REPO_ROOT"

# Verify required files exist
if [ ! -f "$REPO_ROOT/testing/on-prem/disaster_scenarios/disaster_scenarios.json" ]; then
    echo "ERROR: Disaster scenarios not found"
    exit 1
fi

if [ ! -d "$DR_DASHBOARD_DIR/recovery_processes/on-prem" ]; then
    echo "ERROR: Recovery processes not found"
    exit 1
fi

# Build image name
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"
else
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"
fi

# Determine if we need sudo for docker
DOCKER_CMD="docker"
if ! docker info > /dev/null 2>&1; then
    if sudo docker info > /dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
        echo "Using sudo for docker commands"
    else
        echo "ERROR: Docker is not running or not accessible"
        echo "  On WSL: sudo service docker start"
        echo "  On macOS: Start Docker Desktop"
        exit 1
    fi
fi

# Build the image
echo "Building: $FULL_IMAGE"
$DOCKER_CMD build \
    -f "$SCRIPT_DIR/Dockerfile" \
    -t "$FULL_IMAGE" \
    "$REPO_ROOT"

echo ""
echo "Build complete: $FULL_IMAGE"
echo ""
echo "Run locally:"
echo "  $DOCKER_CMD run -p 8080:8080 $FULL_IMAGE"

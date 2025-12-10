#!/bin/bash
#
# Start the PXC Restore API server
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}PXC Point-in-Time Restore Service${NC}"
echo ""

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "Go is not installed. Please install Go 1.21 or later."
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl is not installed or not in PATH."
    exit 1
fi

# Check kubectl connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "Warning: Cannot connect to Kubernetes cluster. KUBECONFIG may not be set correctly."
fi

PORT="${PORT:-8081}"

echo "Starting server on port ${PORT}..."
echo ""
echo -e "${GREEN}Web UI:${NC} http://localhost:${PORT}"
echo -e "${GREEN}API:${NC}    http://localhost:${PORT}/api/backups?namespace=<ns>"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Run the Go server
go run main.go

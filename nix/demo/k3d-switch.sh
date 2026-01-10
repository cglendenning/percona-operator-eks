#!/usr/bin/env bash
# k3d cluster context switcher

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== k3d Cluster Switcher ===${NC}"
echo ""

# List all k3d clusters
echo -e "${GREEN}Available k3d clusters:${NC}"
k3d cluster list
echo ""

# List all contexts
echo -e "${GREEN}Available kubectl contexts:${NC}"
kubectl config get-contexts | grep k3d || echo "No k3d contexts found"
echo ""

# Show current context
CURRENT=$(kubectl config current-context 2>/dev/null || echo "none")
echo -e "${YELLOW}Current context: ${CURRENT}${NC}"
echo ""

# Interactive switch
if [ $# -eq 0 ]; then
    echo "Usage: $0 <cluster-name>"
    echo ""
    echo "Examples:"
    echo "  $0 cluster-a        # Switch to k3d-cluster-a"
    echo "  $0 cluster-b        # Switch to k3d-cluster-b"
    echo "  $0 wookie-local     # Switch to k3d-wookie-local"
    exit 0
fi

CLUSTER_NAME="$1"
CONTEXT="k3d-${CLUSTER_NAME}"

# Check if context exists
if kubectl config get-contexts "$CONTEXT" &>/dev/null; then
    kubectl config use-context "$CONTEXT"
    echo ""
    echo -e "${GREEN}Switched to ${CONTEXT}${NC}"
    echo ""
    echo "Cluster info:"
    kubectl cluster-info
else
    echo -e "${YELLOW}Context ${CONTEXT} not found${NC}"
    echo ""
    echo "Available k3d contexts:"
    kubectl config get-contexts | grep k3d
    exit 1
fi

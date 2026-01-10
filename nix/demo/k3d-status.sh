#!/usr/bin/env bash
# Show status of all k3d clusters

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== k3d Cluster Status ===${NC}"
echo ""

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
echo -e "${YELLOW}Current context: ${CURRENT_CONTEXT}${NC}"
echo ""

# Get list of k3d clusters
CLUSTERS=$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo "")

if [ -z "$CLUSTERS" ]; then
    echo "No k3d clusters found"
    exit 0
fi

echo -e "${GREEN}Running k3d clusters:${NC}"
echo ""

for cluster in $CLUSTERS; do
    CONTEXT="k3d-${cluster}"
    
    # Check if this is the current context
    if [ "$CONTEXT" = "$CURRENT_CONTEXT" ]; then
        MARKER="→"
        COLOR=$GREEN
    else
        MARKER=" "
        COLOR=$NC
    fi
    
    echo -e "${COLOR}${MARKER} ${cluster}${NC}"
    echo "   Context: ${CONTEXT}"
    
    # Get node count
    NODE_COUNT=$(kubectl get nodes --context "$CONTEXT" 2>/dev/null | grep -c Ready || echo "0")
    echo "   Nodes: ${NODE_COUNT}"
    
    # Get pod count across all namespaces
    POD_COUNT=$(kubectl get pods -A --context "$CONTEXT" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo "   Pods: ${POD_COUNT}"
    
    # Check if Istio is installed
    if kubectl get namespace istio-system --context "$CONTEXT" &>/dev/null; then
        ISTIO_PODS=$(kubectl get pods -n istio-system --context "$CONTEXT" 2>/dev/null | grep -c Running || echo "0")
        echo "   Istio: ✓ (${ISTIO_PODS} pods running)"
    else
        echo "   Istio: ✗"
    fi
    
    # Check demo namespace
    if kubectl get namespace demo --context "$CONTEXT" &>/dev/null; then
        DEMO_PODS=$(kubectl get pods -n demo --context "$CONTEXT" 2>/dev/null | grep -c Running || echo "0")
        echo "   demo namespace: ${DEMO_PODS} pods"
    fi
    
    # Check demo-dr namespace
    if kubectl get namespace demo-dr --context "$CONTEXT" &>/dev/null; then
        DEMO_DR_PODS=$(kubectl get pods -n demo-dr --context "$CONTEXT" 2>/dev/null | grep -c Running || echo "0")
        echo "   demo-dr namespace: ${DEMO_DR_PODS} pods"
    fi
    
    echo ""
done

echo ""
echo "Quick switch:"
echo "  ./k3d-switch.sh cluster-a     # Switch to k3d-cluster-a"
echo "  ./k3d-switch.sh cluster-b     # Switch to k3d-cluster-b"

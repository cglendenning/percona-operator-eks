#!/bin/bash

# LitmusChaos Installation Script
set -e

# Configuration
LITMUS_NAMESPACE="litmus"
LITMUS_VERSION="3.1.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Please install helm."
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    
    log_info "Prerequisites met"
}

# Install LitmusChaos
install_litmus() {
    log_step "Installing LitmusChaos ${LITMUS_VERSION}..."
    
    # Create namespace if it doesn't exist
    if ! kubectl get namespace "${LITMUS_NAMESPACE}" &> /dev/null; then
        log_info "Creating namespace ${LITMUS_NAMESPACE}..."
        kubectl create namespace "${LITMUS_NAMESPACE}"
    fi
    
    # Add LitmusChaos Helm repo
    log_info "Adding LitmusChaos Helm repository..."
    helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/ 2>/dev/null || true
    helm repo update
    
    # Install LitmusChaos CRDs
    log_info "Installing LitmusChaos CRDs..."
    if kubectl get crd chaosengines.litmuschaos.io &> /dev/null; then
        log_info "✓ LitmusChaos CRDs already installed"
    else
        log_info "Installing CRDs from GitHub..."
        curl -sL https://raw.githubusercontent.com/litmuschaos/litmus/v3.1.0/mkdocs/docs/3.1.0/litmus-portal-crds-3.1.0.yml | kubectl apply -f - || {
            log_warn "Primary CRD URL failed, trying alternative..."
            curl -sL https://raw.githubusercontent.com/litmuschaos/litmus/master/litmus-portal/litmus-portal-crds.yaml | kubectl apply -f - || {
                log_error "Failed to install CRDs. Continuing with Portal installation..."
            }
        }
        
        # Wait for CRDs
        kubectl wait --for=condition=Established --timeout=60s \
            crd/chaosengines.litmuschaos.io \
            crd/chaosexperiments.litmuschaos.io \
            crd/chaosresults.litmuschaos.io 2>/dev/null || true
    fi
    
    # Install LitmusChaos Portal via Helm - EXACT command from official docs
    # Reference: https://docs.litmuschaos.io/docs/getting-started/installation
    log_info "Installing LitmusChaos Portal..."
    log_info "Using EXACT command from LitmusChaos documentation..."
    
    # Exact command from docs: helm install chaos litmuschaos/litmus --namespace=litmus --set portal.frontend.service.type=NodePort
    helm install chaos litmuschaos/litmus \
        --namespace="${LITMUS_NAMESPACE}" \
        --set portal.frontend.service.type=NodePort \
        --wait \
        --timeout=10m || {
        log_error "Helm installation failed or timed out!"
        exit 1
    }
    
    log_info "Helm installation completed. Waiting for all pods to be ready..."
    
    # Wait and monitor pods with explicit ImagePullBackOff detection
    MAX_WAIT=600  # 10 minutes total
    ELAPSED=0
    INTERVAL=10
    
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        # Get all pods in litmus namespace
        PODS_JSON=$(kubectl get pods -n "${LITMUS_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
        
        # Extract pod statuses
        POD_STATUSES=$(echo "$PODS_JSON" | jq -r '.items[] | "\(.metadata.name)|\(.status.phase)|\(.status.containerStatuses[0].state.waiting.reason // .status.containerStatuses[0].state.waiting.message // "none")"')
        
        # Check for ImagePullBackOff or ErrImagePull
        if echo "$POD_STATUSES" | grep -q "ImagePullBackOff\|ErrImagePull"; then
            log_error "❌ CRITICAL: ImagePullBackOff detected!"
            log_error "Failing pods:"
            echo "$POD_STATUSES" | grep -E "ImagePullBackOff|ErrImagePull" | while IFS='|' read -r name phase reason; do
                log_error "  - $name: $phase ($reason)"
                # Get image name
                IMAGE=$(echo "$PODS_JSON" | jq -r ".items[] | select(.metadata.name == \"$name\") | .spec.containers[0].image")
                log_error "    Image: $IMAGE"
            done
            log_error ""
            log_error "Installation FAILED due to image pull errors!"
            exit 1
        fi
        
        # Check if all pods are running
        TOTAL_PODS=$(echo "$POD_STATUSES" | wc -l | tr -d ' ')
        RUNNING_PODS=$(echo "$POD_STATUSES" | grep -c "Running" || echo "0")
        
        if [ "$TOTAL_PODS" -gt 0 ] && [ "$RUNNING_PODS" -eq "$TOTAL_PODS" ]; then
            log_info "✓ All $RUNNING_PODS pods are running!"
            break
        fi
        
        # Show progress
        if [ $((ELAPSED % 30)) -eq 0 ] || [ "$RUNNING_PODS" -gt 0 ]; then
            log_info "[${ELAPSED}s] Pod status: $RUNNING_PODS/$TOTAL_PODS running"
            echo "$POD_STATUSES" | while IFS='|' read -r name phase reason; do
                if [ "$phase" != "Running" ]; then
                    log_info "  - $name: $phase ${reason:+(reason)}"
                fi
            done
        fi
        
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    
    # Final check
    log_info ""
    log_info "=== FINAL POD STATUS ==="
    kubectl get pods -n "${LITMUS_NAMESPACE}"
    log_info ""
    
    # Verify no ImagePullBackOff
    if kubectl get pods -n "${LITMUS_NAMESPACE}" 2>/dev/null | grep -q "ImagePullBackOff\|ErrImagePull"; then
        log_error "❌ Installation FAILED: Pods still in ImagePullBackOff state!"
        exit 1
    fi
    
    # Verify all pods are ready
    READY_COUNT=$(kubectl get pods -n "${LITMUS_NAMESPACE}" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_COUNT=$(kubectl get pods -n "${LITMUS_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$READY_COUNT" -lt "$TOTAL_COUNT" ]; then
        log_warn "⚠ Not all pods are running yet ($READY_COUNT/$TOTAL_COUNT)"
        log_warn "Pods may still be starting. Current status:"
        kubectl get pods -n "${LITMUS_NAMESPACE}" | grep -v Running || true
    else
        log_info "✓ All $TOTAL_COUNT pods are ready!"
    fi
}

# Verify installation
verify_installation() {
    log_step "Verifying LitmusChaos installation..."
    
    # Check if CRDs are installed
    if kubectl get crd chaosengines.litmuschaos.io &> /dev/null; then
        log_info "✓ LitmusChaos CRDs are installed"
    else
        log_error "✗ LitmusChaos CRDs are NOT installed!"
        return 1
    fi
}

# Main execution
main() {
    log_info "Starting LitmusChaos installation..."
    
    check_prerequisites
    install_litmus
    verify_installation
    
    log_info ""
    log_info "✓ LitmusChaos installation completed successfully!"
    log_info "Namespace: ${LITMUS_NAMESPACE}"
    log_info ""
    log_info "To access the LitmusChaos UI:"
    log_info "  kubectl port-forward -n ${LITMUS_NAMESPACE} svc/litmus-portal-frontend 8080:9091"
}

main "$@"

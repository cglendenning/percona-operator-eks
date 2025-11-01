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
    helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
    helm repo update
    
    # Install LitmusChaos
    log_info "Installing LitmusChaos (this may take a few minutes)..."
    helm upgrade --install litmus litmuschaos/litmus \
        --namespace="${LITMUS_NAMESPACE}" \
        --version="${LITMUS_VERSION}" \
        --set adminConfig.DBUSER="admin" \
        --set adminConfig.DBPASSWORD="litmus" \
        --set image.imageTag="${LITMUS_VERSION}" \
        --wait \
        --timeout=10m
    
    log_info "Waiting for LitmusChaos pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=litmus \
        -n "${LITMUS_NAMESPACE}" \
        --timeout=300s
    
    log_info "LitmusChaos installed successfully!"
}

# Verify installation
verify_installation() {
    log_step "Verifying LitmusChaos installation..."
    
    # Check if pods are running
    local ready_pods=$(kubectl get pods -n "${LITMUS_NAMESPACE}" \
        -l app.kubernetes.io/name=litmus \
        --field-selector=status.phase=Running \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$ready_pods" -lt "1" ]; then
        log_warn "LitmusChaos pods may still be starting..."
        kubectl get pods -n "${LITMUS_NAMESPACE}"
    else
        log_info "✓ LitmusChaos components are running"
    fi
    
    # Check if CRDs are installed
    if kubectl get crd chaosengines.litmuschaos.io &> /dev/null; then
        log_info "✓ LitmusChaos CRDs are installed"
    else
        log_warn "LitmusChaos CRDs may still be installing..."
    fi
}

# Main execution
main() {
    log_info "Starting LitmusChaos installation..."
    
    check_prerequisites
    install_litmus
    verify_installation
    
    log_info ""
    log_info "LitmusChaos installation completed!"
    log_info "Namespace: ${LITMUS_NAMESPACE}"
    log_info ""
    log_info "To access the LitmusChaos UI:"
    log_info "  kubectl port-forward -n ${LITMUS_NAMESPACE} svc/litmus-portal-frontend 8080:9091"
    log_info "  Then open http://localhost:8080 in your browser"
    log_info ""
    log_info "To view chaos experiments:"
    log_info "  kubectl get chaosexperiments -n ${LITMUS_NAMESPACE}"
}

main "$@"


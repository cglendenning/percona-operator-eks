#!/bin/bash

# ChartMuseum Setup Script for EKS with Local Storage
# This script sets up ChartMuseum with local filesystem storage on your EKS cluster

set -e

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Check if running under WSL
        if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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
    echo -e "${BOLD}${GREEN}[STEP]${NC} $1"
}

# Configuration
NAMESPACE="${NAMESPACE:-chartmuseum}"
SERVICE_TYPE="${SERVICE_TYPE:-ClusterIP}"  # ClusterIP for internal use
STORAGE_CLASS="${STORAGE_CLASS:-gp3}"  # EBS gp3 storage class
STORAGE_SIZE="${STORAGE_SIZE:-50Gi}"  # Storage size for charts

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed. Aborting."; exit 1; }
    command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed. Aborting."; exit 1; }
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

# Install ChartMuseum with local storage
install_chartmuseum() {
    log_step "Installing ChartMuseum with local persistent storage..."
    
    # Create namespace if it doesn't exist
    if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Creating namespace: ${NAMESPACE}"
        kubectl create namespace "${NAMESPACE}"
    else
        log_info "Namespace ${NAMESPACE} already exists"
    fi
    
    # Add ChartMuseum Helm repository if not already added
    if ! helm repo list | grep -q "^chartmuseum"; then
        log_info "Adding ChartMuseum Helm repository..."
        helm repo add chartmuseum https://chartmuseum.github.io/charts
    fi
    
    log_info "Updating Helm repositories..."
    helm repo update
    
    # Check if ChartMuseum is already installed
    UPGRADE=false
    if helm list -n "${NAMESPACE}" | grep -q chartmuseum; then
        log_warn "ChartMuseum is already installed. Upgrading..."
        UPGRADE=true
    else
        UPGRADE=false
    fi
    
    # Install/upgrade ChartMuseum with local storage
    log_info "Installing ChartMuseum with local persistent storage..."
    if [ "$UPGRADE" = true ]; then
        helm upgrade chartmuseum chartmuseum/chartmuseum \
            --namespace "${NAMESPACE}" \
            --set env.open.DISABLE_API=false \
            --set env.open.STORAGE=local \
            --set env.open.STORAGE_LOCAL_ROOTDIR=/storage \
            --set persistence.enabled=true \
            --set persistence.accessMode=ReadWriteOnce \
            --set persistence.size="${STORAGE_SIZE}" \
            --set persistence.storageClass="${STORAGE_CLASS}" \
            --set service.type="${SERVICE_TYPE}" \
            --set resources.requests.memory=256Mi \
            --set resources.requests.cpu=100m \
            --set resources.limits.memory=512Mi \
            --set resources.limits.cpu=500m \
            --wait \
            --timeout=5m
    else
        helm install chartmuseum chartmuseum/chartmuseum \
            --namespace "${NAMESPACE}" \
            --set env.open.DISABLE_API=false \
            --set env.open.STORAGE=local \
            --set env.open.STORAGE_LOCAL_ROOTDIR=/storage \
            --set persistence.enabled=true \
            --set persistence.accessMode=ReadWriteOnce \
            --set persistence.size="${STORAGE_SIZE}" \
            --set persistence.storageClass="${STORAGE_CLASS}" \
            --set service.type="${SERVICE_TYPE}" \
            --set resources.requests.memory=256Mi \
            --set resources.requests.cpu=100m \
            --set resources.limits.memory=512Mi \
            --set resources.limits.cpu=500m \
            --wait \
            --timeout=5m
    fi
    
    log_info "ChartMuseum installed successfully"
    
    # Wait for pod to be ready
    log_info "Waiting for ChartMuseum pod to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=chartmuseum \
        -n "${NAMESPACE}" \
        --timeout=300s
    
    # Get service URL (internal ClusterIP)
    CHARTMUSEUM_URL="http://chartmuseum.${NAMESPACE}.svc.cluster.local:8080"
    
    echo "${CHARTMUSEUM_URL}" > /tmp/chartmuseum-url.txt
    log_info "ChartMuseum URL: ${CHARTMUSEUM_URL}"
}

# Verify installation
verify_installation() {
    log_step "Verifying ChartMuseum installation..."
    
    CHARTMUSEUM_URL=$(cat /tmp/chartmuseum-url.txt)
    
    # Check if pod is running
    POD_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=chartmuseum -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$POD_STATUS" = "Running" ]; then
        log_info "✓ ChartMuseum pod is running"
    else
        log_warn "ChartMuseum pod status: $POD_STATUS"
    fi
    
    # Test adding repo (will verify later with mirroring)
    log_info "ChartMuseum is ready for chart mirroring"
    log_info "Run percona/scripts/mirror-charts.sh to populate the repository"
}

# Print summary
print_summary() {
    log_step "Installation Summary"
    
    CHARTMUSEUM_URL=$(cat /tmp/chartmuseum-url.txt 2>/dev/null || echo "http://chartmuseum.${NAMESPACE}.svc.cluster.local:8080")
    
    echo ""
    echo -e "${BOLD}ChartMuseum Installation Complete!${NC}"
    echo ""
    echo -e "${CYAN}ChartMuseum URL (internal):${NC} ${CHARTMUSEUM_URL}"
    echo -e "${CYAN}Namespace:${NC} ${NAMESPACE}"
    echo -e "${CYAN}Storage Type:${NC} Local persistent storage (${STORAGE_SIZE} on ${STORAGE_CLASS})"
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo "1. Mirror charts to ChartMuseum:"
    echo "   ${CYAN}percona/scripts/mirror-charts.sh${NC}"
    echo ""
    echo "2. Add ChartMuseum as a Helm repository:"
    echo "   ${CYAN}helm repo add internal ${CHARTMUSEUM_URL}${NC}"
    echo "   ${CYAN}helm repo update${NC}"
    echo ""
    echo "3. Search for charts:"
    echo "   ${CYAN}helm search repo internal${NC}"
    echo ""
}

# Main execution
main() {
    log_step "Starting ChartMuseum setup with local storage"
    log_info "Namespace: ${NAMESPACE}"
    log_info "Storage: Local persistent storage (${STORAGE_SIZE} on ${STORAGE_CLASS})"
    
    check_prerequisites
    install_chartmuseum
    verify_installation
    print_summary
}

# Run main function
main

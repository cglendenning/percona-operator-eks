#!/bin/bash
# PMM v3 Server Uninstallation Script for On-Premise Kubernetes
# Removes Percona Monitoring and Management Server v3 from Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PMM_NAMESPACE="pmm"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

log_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_header "Checking Prerequisites"
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    log_success "kubectl found"
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Confirm uninstallation
confirm_uninstall() {
    log_header "Uninstallation Confirmation"
    
    if ! kubectl get namespace "$PMM_NAMESPACE" &>/dev/null; then
        log_error "PMM namespace '$PMM_NAMESPACE' not found"
        log_info "Nothing to uninstall."
        exit 0
    fi
    
    echo -e "${YELLOW}WARNING: This will remove PMM Server and ALL monitoring data!${NC}"
    echo ""
    echo "Namespace to be deleted: ${PMM_NAMESPACE}"
    echo ""
    
    # Check for PVCs
    local pvc_count=$(kubectl get pvc -n "$PMM_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pvc_count" -gt 0 ]; then
        echo "Storage to be deleted:"
        kubectl get pvc -n "$PMM_NAMESPACE" 2>/dev/null | awk 'NR>1 {print "  - " $1 " (" $4 ")"}'
        echo ""
    fi
    
    read -p "Are you sure you want to uninstall PMM Server? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Uninstallation cancelled."
        exit 0
    fi
}

# Delete PMM Server resources
delete_pmm_resources() {
    log_header "Deleting PMM Server Resources"
    
    # Delete StatefulSet
    if kubectl get statefulset pmm-server -n "$PMM_NAMESPACE" &>/dev/null; then
        log_info "Deleting PMM Server StatefulSet..."
        kubectl delete statefulset pmm-server -n "$PMM_NAMESPACE" --grace-period=30
        log_success "StatefulSet deleted"
    fi
    
    # Delete Services
    if kubectl get svc monitoring-service -n "$PMM_NAMESPACE" &>/dev/null; then
        log_info "Deleting monitoring-service..."
        kubectl delete svc monitoring-service -n "$PMM_NAMESPACE"
        log_success "Service deleted"
    fi
    
    # Delete ServiceAccount and Token Secret
    if kubectl get sa pmm-server -n "$PMM_NAMESPACE" &>/dev/null; then
        log_info "Deleting service account..."
        kubectl delete sa pmm-server -n "$PMM_NAMESPACE"
        log_success "Service account deleted"
    fi
    
    if kubectl get secret pmm-server-token -n "$PMM_NAMESPACE" &>/dev/null; then
        kubectl delete secret pmm-server-token -n "$PMM_NAMESPACE"
        log_success "Token secret deleted"
    fi
    
    # Wait for pods to terminate
    log_info "Waiting for PMM Server pod to terminate..."
    kubectl wait --for=delete pod -l app=pmm-server -n "$PMM_NAMESPACE" --timeout=120s 2>/dev/null || true
}

# Delete PVCs and storage
delete_storage() {
    log_header "Deleting Persistent Storage"
    
    local pvcs=$(kubectl get pvc -n "$PMM_NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
    
    if [ -z "$pvcs" ]; then
        log_info "No PVCs found"
        return
    fi
    
    log_info "Deleting PVCs..."
    for pvc in $pvcs; do
        local capacity=$(kubectl get pvc "$pvc" -n "$PMM_NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "unknown")
        log_info "  Deleting $pvc ($capacity)..."
        kubectl delete pvc "$pvc" -n "$PMM_NAMESPACE" --wait=false
    done
    
    log_warn "PVC deletion initiated (may take a few moments to complete)"
    
    # Calculate total storage
    local total_storage=$(kubectl get pvc -n "$PMM_NAMESPACE" -o jsonpath='{range .items[*]}{.status.capacity.storage}{"\n"}{end}' 2>/dev/null | \
        awk '{sum+=$1} END {print sum}' || echo "0")
    
    if [ "$total_storage" != "0" ]; then
        log_info "Total storage being released: ${total_storage}Gi"
    fi
}

# Delete namespace
delete_namespace() {
    log_header "Deleting PMM Namespace"
    
    log_info "Deleting namespace '$PMM_NAMESPACE'..."
    kubectl delete namespace "$PMM_NAMESPACE" --wait=false
    
    log_warn "Namespace deletion initiated (may take a few moments to complete)"
    log_info "Monitor deletion with: kubectl get namespace $PMM_NAMESPACE"
}

# Display summary
display_summary() {
    log_header "Uninstallation Summary"
    
    echo -e "${GREEN}PMM Server has been uninstalled.${NC}"
    echo ""
    echo "Resources removed:"
    echo "  ✓ PMM Server StatefulSet"
    echo "  ✓ PMM Services"
    echo "  ✓ Service Account and Tokens"
    echo "  ✓ Persistent Storage"
    echo "  ✓ PMM Namespace"
    echo ""
    
    log_info "Verify removal with:"
    echo "  kubectl get namespace $PMM_NAMESPACE"
    echo ""
    
    log_success "Uninstallation complete!"
}

# Main uninstallation flow
main() {
    log_header "PMM Server v3 Uninstaller for On-Premise Kubernetes"
    
    check_prerequisites
    confirm_uninstall
    delete_pmm_resources
    delete_storage
    delete_namespace
    display_summary
}

# Run main uninstallation
main


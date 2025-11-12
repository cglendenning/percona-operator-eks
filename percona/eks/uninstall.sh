#!/bin/bash
# Percona XtraDB Cluster Uninstallation Script for EKS
# Works on both WSL and macOS

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default configuration
NAMESPACE=""
DELETE_PVCS="no"
DELETE_NAMESPACE="no"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Check prerequisites
check_prerequisites() {
    log_header "Checking Prerequisites"
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl and try again."
        exit 1
    fi
    log_success "kubectl found"
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Please install helm and try again."
        exit 1
    fi
    log_success "helm found"
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please configure kubectl and try again"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Prompt for namespace
prompt_namespace() {
    log_header "Percona XtraDB Cluster Uninstaller for EKS"
    
    # List namespaces with Percona resources
    log_info "Namespaces with Percona resources:"
    kubectl get pxc --all-namespaces 2>/dev/null | grep -v "^NAMESPACE" | awk '{print "  - " $1}' || echo "  (none found)"
    echo ""
    
    read -p "Enter namespace to uninstall from: " namespace_input
    NAMESPACE="$namespace_input"
    
    if [ -z "$NAMESPACE" ]; then
        log_error "Namespace cannot be empty"
        exit 1
    fi
    
    # Verify namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist"
        exit 1
    fi
    
    log_success "Found namespace: $NAMESPACE"
}

# Show what will be deleted
show_resources() {
    log_header "Resources in Namespace: $NAMESPACE"
    
    echo -e "${MAGENTA}═══ Helm Releases ═══${NC}"
    local releases=$(helm list -n "$NAMESPACE" --short 2>/dev/null || echo "")
    if [ -n "$releases" ]; then
        echo "$releases" | while read -r release; do
            echo "  - $release"
        done
    else
        echo "  (none found)"
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ PXC Clusters ═══${NC}"
    if kubectl get pxc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        kubectl get pxc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (Age: " $4 ")"}'
    else
        echo "  (none found)"
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Pods ═══${NC}"
    local pod_count=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pod_count" -gt 0 ]; then
        kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $3 ")"}'
    else
        echo "  (none found)"
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Services ═══${NC}"
    local svc_count=$(kubectl get svc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$svc_count" -gt 0 ]; then
        kubectl get svc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $2 ")"}'
    else
        echo "  (none found)"
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Persistent Volume Claims ═══${NC}"
    local pvc_count=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pvc_count" -gt 0 ]; then
        kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $2 ", " $3 ")"}'
        echo ""
        
        # Calculate total storage
        local total_storage=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | sed 's/Gi//' | awk '{sum+=$1} END {print sum}')
        log_warn "Total storage: ${total_storage}Gi"
        
        # Show associated Persistent Volumes
        echo ""
        echo -e "${MAGENTA}═══ Associated Persistent Volumes ═══${NC}"
        kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | while read -r pv; do
            if [ -n "$pv" ] && [ "$pv" != "<none>" ]; then
                local pv_info=$(kubectl get pv "$pv" --no-headers 2>/dev/null | awk '{print $1 " (" $2 ", " $5 ", " $6 ")"}' || echo "$pv (details unavailable)")
                echo "  - $pv_info"
            fi
        done
    else
        echo "  (none found)"
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Secrets ═══${NC}"
    local secret_count=$(kubectl get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token" | wc -l | tr -d ' ')
    if [ "$secret_count" -gt 0 ]; then
        kubectl get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token" | awk '{print "  - " $1 " (" $2 ")"}'
    else
        echo "  (none found)"
    fi
    echo ""
}

# Confirm deletion
confirm_deletion() {
    log_header "Confirm Deletion"
    
    echo -e "${RED}⚠️  WARNING: This will delete the following from namespace '${NAMESPACE}':${NC}"
    echo "  - Helm releases (PXC cluster, Percona operator)"
    echo "  - PXC cluster custom resources"
    echo "  - All pods, services, deployments, statefulsets"
    echo "  - Secrets (including root passwords)"
    echo ""
    
    read -p "Are you sure you want to proceed? (type 'yes' to confirm): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Uninstallation cancelled by user"
        exit 0
    fi
    
    echo ""
    read -p "Do you want to delete PVCs and PVs? (yes/no) [no]: " delete_pvcs_input
    DELETE_PVCS="${delete_pvcs_input:-no}"
    
    if [ "$DELETE_PVCS" = "yes" ]; then
        echo ""
        echo -e "${RED}⚠️  WARNING: Deleting PVCs will permanently delete all database data!${NC}"
        echo -e "${RED}⚠️  This action CANNOT be undone!${NC}"
        echo ""
        read -p "Type 'DELETE ALL DATA' to confirm PVC deletion: " final_confirm
        if [ "$final_confirm" != "DELETE ALL DATA" ]; then
            log_info "PVC deletion cancelled. Cluster will be removed but data will be preserved."
            DELETE_PVCS="no"
        fi
    fi
    
    echo ""
    read -p "Do you want to delete the namespace '$NAMESPACE'? (yes/no) [no]: " delete_ns_input
    DELETE_NAMESPACE="${delete_ns_input:-no}"
}

# Uninstall Helm releases
uninstall_helm_releases() {
    log_header "Uninstalling Helm Releases"
    
    local releases=$(helm list -n "$NAMESPACE" --short 2>/dev/null || echo "")
    
    if [ -z "$releases" ]; then
        log_info "No Helm releases found in namespace $NAMESPACE"
        return
    fi
    
    echo "$releases" | while read -r release; do
        if [ -n "$release" ]; then
            log_info "Uninstalling Helm release: $release"
            helm uninstall "$release" -n "$NAMESPACE" --wait --timeout 5m 2>/dev/null || \
                log_warn "Failed to uninstall $release (may already be deleted)"
            log_success "Helm release '$release' uninstalled"
        fi
    done
}

# Delete PXC custom resources
delete_pxc_resources() {
    log_header "Deleting PXC Custom Resources"
    
    # Delete PXC clusters
    if kubectl get pxc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_info "Deleting PXC cluster custom resources..."
        kubectl delete pxc --all -n "$NAMESPACE" --wait --timeout=300s 2>/dev/null || \
            log_warn "Some PXC resources may not have been deleted cleanly"
        log_success "PXC clusters deleted"
    else
        log_info "No PXC cluster resources found"
    fi
    
    # Delete PXC backups
    if kubectl get pxc-backup -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_info "Deleting PXC backup custom resources..."
        kubectl delete pxc-backup --all -n "$NAMESPACE" --wait --timeout=60s 2>/dev/null || \
            log_warn "Some backup resources may not have been deleted cleanly"
        log_success "PXC backups deleted"
    fi
    
    # Delete PXC restores
    if kubectl get pxc-restore -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_info "Deleting PXC restore custom resources..."
        kubectl delete pxc-restore --all -n "$NAMESPACE" --wait --timeout=60s 2>/dev/null || \
            log_warn "Some restore resources may not have been deleted cleanly"
        log_success "PXC restores deleted"
    fi
}

# Delete remaining resources
delete_remaining_resources() {
    log_header "Deleting Remaining Resources"
    
    # Delete deployments
    if kubectl get deployments -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_info "Deleting deployments..."
        kubectl delete deployments --all -n "$NAMESPACE" --wait --timeout=120s 2>/dev/null || \
            log_warn "Some deployments may not have been deleted cleanly"
    fi
    
    # Delete statefulsets
    if kubectl get statefulsets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_info "Deleting statefulsets..."
        kubectl delete statefulsets --all -n "$NAMESPACE" --wait --timeout=120s 2>/dev/null || \
            log_warn "Some statefulsets may not have been deleted cleanly"
    fi
    
    # Delete services
    if kubectl get services -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_info "Deleting services..."
        kubectl delete services --all -n "$NAMESPACE" 2>/dev/null || \
            log_warn "Some services may not have been deleted cleanly"
    fi
    
    log_success "Remaining resources deleted"
}

# Delete PVCs and PVs
delete_storage() {
    if [ "$DELETE_PVCS" != "yes" ]; then
        log_header "Preserving Persistent Storage"
        log_warn "PVCs and PVs have been preserved. Database data is still available."
        log_info "To view preserved PVCs: kubectl get pvc -n $NAMESPACE"
        log_info "To delete them later: kubectl delete pvc --all -n $NAMESPACE"
        return
    fi
    
    log_header "Deleting Persistent Storage"
    
    # Get list of PVs before deleting PVCs
    local pvs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | grep -v "<none>" || echo "")
    
    # Delete PVCs
    if kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_warn "Deleting all PVCs in namespace $NAMESPACE..."
        kubectl delete pvc --all -n "$NAMESPACE" --wait --timeout=300s 2>/dev/null || \
            log_warn "Some PVCs may not have been deleted cleanly"
        log_success "PVCs deleted"
        
        # Wait a moment for PVs to be released
        sleep 5
        
        # Check if PVs still exist and warn
        if [ -n "$pvs" ]; then
            echo ""
            log_info "Checking status of Persistent Volumes..."
            echo "$pvs" | while read -r pv; do
                if [ -n "$pv" ]; then
                    local pv_status=$(kubectl get pv "$pv" --no-headers 2>/dev/null | awk '{print $5}' || echo "Deleted")
                    if [ "$pv_status" = "Released" ]; then
                        log_warn "PV $pv is in 'Released' state (may need manual cleanup)"
                    elif [ "$pv_status" != "Deleted" ]; then
                        log_info "PV $pv: $pv_status"
                    fi
                fi
            done
        fi
    else
        log_info "No PVCs found to delete"
    fi
}

# Delete namespace
delete_namespace() {
    if [ "$DELETE_NAMESPACE" != "yes" ]; then
        log_header "Preserving Namespace"
        log_info "Namespace '$NAMESPACE' has been preserved"
        return
    fi
    
    log_header "Deleting Namespace"
    
    log_warn "Deleting namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --wait --timeout=300s 2>/dev/null || \
        log_warn "Namespace deletion may be taking longer than expected"
    
    # Check if namespace is gone
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace '$NAMESPACE' still exists (may be stuck in 'Terminating' state)"
        log_info "You may need to manually clean up finalizers"
    else
        log_success "Namespace '$NAMESPACE' deleted"
    fi
}

# Display completion summary
show_summary() {
    log_header "Uninstallation Complete"
    
    echo -e "${GREEN}✓${NC} Percona XtraDB Cluster uninstalled from namespace: ${NAMESPACE}"
    echo ""
    
    if [ "$DELETE_PVCS" = "yes" ]; then
        echo -e "${GREEN}✓${NC} All data deleted (PVCs and PVs removed)"
    else
        echo -e "${YELLOW}ℹ${NC} Data preserved (PVCs remain)"
        echo "  View: ${CYAN}kubectl get pvc -n $NAMESPACE${NC}"
        echo "  Delete later: ${CYAN}kubectl delete pvc --all -n $NAMESPACE${NC}"
    fi
    echo ""
    
    if [ "$DELETE_NAMESPACE" = "yes" ]; then
        echo -e "${GREEN}✓${NC} Namespace deleted"
    else
        echo -e "${YELLOW}ℹ${NC} Namespace preserved: ${NAMESPACE}"
        echo "  Delete later: ${CYAN}kubectl delete namespace $NAMESPACE${NC}"
    fi
    echo ""
    
    log_success "Uninstallation completed successfully!"
}

# Main uninstallation flow
main() {
    check_prerequisites
    prompt_namespace
    show_resources
    confirm_deletion
    
    echo ""
    log_info "Starting uninstallation process..."
    echo ""
    
    uninstall_helm_releases
    delete_pxc_resources
    delete_remaining_resources
    delete_storage
    delete_namespace
    
    show_summary
}

# Run main function
main "$@"


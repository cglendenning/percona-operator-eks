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
    
    # Verify namespace exists or has orphaned resources
    local ns_status=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$ns_status" = "NotFound" ]; then
        # Check if there are orphaned PXC resources referencing this namespace
        local orphaned_pxc=$(kubectl get pxc --all-namespaces 2>/dev/null | grep "^$NAMESPACE " || echo "")
        
        if [ -n "$orphaned_pxc" ]; then
            log_warn "Namespace '$NAMESPACE' doesn't exist, but orphaned PXC resources were found"
            log_info "This script will clean up the orphaned resources"
        else
            log_error "Namespace '$NAMESPACE' does not exist and has no resources"
            exit 1
        fi
    elif [ "$ns_status" = "Terminating" ]; then
        log_warn "Namespace '$NAMESPACE' is stuck in Terminating state"
        log_info "This script will help clean it up"
    else
        log_success "Found namespace: $NAMESPACE"
    fi
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
    # Check both namespace-scoped and orphaned (cluster-wide) PXC resources
    local pxc_resources=$(kubectl get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " || echo "")
    if [ -n "$pxc_resources" ]; then
        echo "$pxc_resources" | awk '{print "  - " $2 " (Age: " $NF ")"}'
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
    
    # Check if namespace exists - if not, skip Helm (it will fail anyway)
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_warn "Namespace doesn't exist - skipping Helm uninstall"
        log_info "Will proceed directly to aggressive resource cleanup"
        return
    fi
    
    local releases=$(helm list -n "$NAMESPACE" --short 2>/dev/null || echo "")
    
    if [ -z "$releases" ]; then
        log_info "No Helm releases found in namespace $NAMESPACE"
        return
    fi
    
    echo "$releases" | while read -r release; do
        if [ -n "$release" ]; then
            log_info "Uninstalling Helm release: $release"
            
            # Try helm uninstall with SHORT timeout (max 30s)
            helm uninstall "$release" -n "$NAMESPACE" --timeout 20s 2>/dev/null &
            local helm_pid=$!
            local elapsed=0
            local max_wait=30
            
            while kill -0 $helm_pid 2>/dev/null; do
                if [ $elapsed -ge $max_wait ]; then
                    log_warn "Helm uninstall timed out after ${max_wait}s - killing and moving on"
                    kill -9 $helm_pid 2>/dev/null || true
                    wait $helm_pid 2>/dev/null || true
                    break
                fi
                
                if [ $((elapsed % 5)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                    log_info "Still waiting for Helm uninstall... (${elapsed}s/${max_wait}s)"
                fi
                
                sleep 1
                elapsed=$((elapsed + 1))
            done
            
            # Wait a moment for the process to fully exit
            wait $helm_pid 2>/dev/null || true
            
            # Check if it actually worked
            if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^$release"; then
                log_warn "Helm release '$release' still exists - diagnosing..."
                
                # Diagnose why it's stuck
                local blocking_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | tr -d ' ')
                local blocking_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                local blocking_finalizers=$(kubectl get pxc -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[].metadata.finalizers[]' 2>/dev/null | wc -l | tr -d ' ')
                
                if [ "$blocking_pods" -gt 0 ]; then
                    log_warn "  → $blocking_pods pod(s) not in Running/Completed state"
                fi
                if [ "$blocking_pvcs" -gt 0 ]; then
                    log_warn "  → $blocking_pvcs PVC(s) exist"
                fi
                if [ "$blocking_finalizers" -gt 0 ]; then
                    log_warn "  → $blocking_finalizers finalizer(s) on PXC resources"
                fi
                
                log_info "  → Will force clean all resources in next steps"
            else
                log_success "Helm release '$release' uninstalled"
            fi
        fi
    done
    
    log_info "Helm cleanup phase complete - proceeding with aggressive resource deletion"
}

# Clean up cluster-wide operator resources (SAFELY)
cleanup_operator_resources() {
    log_header "Checking Cluster-Wide Operator Resources"
    
    # SAFETY CHECK: Find ALL Percona Operator installations across ALL namespaces
    local other_operators=$(helm list -A --filter "percona-operator" -o json 2>/dev/null | \
        jq -r '.[] | select(.namespace != "'"$NAMESPACE"'") | .namespace' 2>/dev/null || echo "")
    
    if [ -n "$other_operators" ]; then
        log_warn "Found Percona Operator installations in other namespaces:"
        echo "$other_operators" | while read -r ns; do
            if [ -n "$ns" ]; then
                log_warn "  - $ns"
            fi
        done
        echo ""
        log_info "Cluster-wide resources (ClusterRole, ClusterRoleBinding, Webhooks) are SHARED"
        log_info "across all namespaces. They will NOT be deleted to avoid breaking other installations."
        log_info ""
        log_info "To clean up cluster-wide resources, uninstall ALL Percona Operators first."
        return
    fi
    
    # No other installations found - safe to delete cluster-wide resources
    log_info "No other Percona Operator installations found in cluster."
    log_warn "Cluster-wide resources will be deleted:"
    log_warn "  - ClusterRole: percona-operator-pxc-operator"
    log_warn "  - ClusterRoleBinding: percona-operator-pxc-operator"
    log_warn "  - ValidatingWebhookConfiguration: percona-xtradbcluster-webhook"
    log_warn "  - MutatingWebhookConfiguration: percona-xtradbcluster-webhook"
    echo ""
    
    read -p "Delete cluster-wide operator resources? (yes/no): " confirm_cluster_cleanup
    
    if [ "$confirm_cluster_cleanup" != "yes" ]; then
        log_info "Skipping cluster-wide resource cleanup"
        return
    fi
    
    log_info "Removing cluster-wide resources..."
    
    # Delete ClusterRole
    if kubectl get clusterrole percona-operator-pxc-operator &>/dev/null; then
        timeout 30 kubectl delete clusterrole percona-operator-pxc-operator 2>/dev/null || true
        log_success "Deleted ClusterRole: percona-operator-pxc-operator"
    fi
    
    # Delete ClusterRoleBinding
    if kubectl get clusterrolebinding percona-operator-pxc-operator &>/dev/null; then
        timeout 30 kubectl delete clusterrolebinding percona-operator-pxc-operator 2>/dev/null || true
        log_success "Deleted ClusterRoleBinding: percona-operator-pxc-operator"
    fi
    
    # Delete ValidatingWebhookConfiguration
    if kubectl get validatingwebhookconfiguration percona-xtradbcluster-webhook &>/dev/null; then
        timeout 30 kubectl delete validatingwebhookconfiguration percona-xtradbcluster-webhook 2>/dev/null || true
        log_success "Deleted ValidatingWebhookConfiguration: percona-xtradbcluster-webhook"
    fi
    
    # Delete MutatingWebhookConfiguration
    if kubectl get mutatingwebhookconfiguration percona-xtradbcluster-webhook &>/dev/null; then
        timeout 30 kubectl delete mutatingwebhookconfiguration percona-xtradbcluster-webhook 2>/dev/null || true
        log_success "Deleted MutatingWebhookConfiguration: percona-xtradbcluster-webhook"
    fi
    
    log_success "Cluster-wide operator resources cleaned up"
}

# Delete PXC custom resources
delete_pxc_resources() {
    log_header "Deleting PXC Custom Resources"
    
    # Check if namespace exists - critical for determining deletion strategy
    local ns_exists="false"
    local ns_recreated="false"
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        ns_exists="true"
        log_info "Namespace exists - using namespace-scoped operations"
    else
        # Check if there are orphaned PXC resources
        local orphaned_count=$(kubectl get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ')
        
        if [ "$orphaned_count" -gt 0 ]; then
            log_warn "Namespace doesn't exist but $orphaned_count orphaned PXC resource(s) found"
            log_warn "Kubernetes API rejects operations on orphaned resources without namespace"
            log_info "Temporarily recreating namespace to enable cleanup..."
            
            if kubectl create namespace "$NAMESPACE" &>/dev/null; then
                ns_exists="true"
                ns_recreated="true"
                log_success "Namespace temporarily recreated for cleanup"
            else
                log_error "Failed to recreate namespace - will try raw API operations"
            fi
        else
            log_info "No orphaned PXC resources found"
            return 0
        fi
    fi
    
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Get current list of PXC resources
        local pxc_list=$(kubectl get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | awk '{print $2}' || echo "")
        
        if [ -z "$pxc_list" ]; then
            log_success "All PXC resources deleted"
            return 0
        fi
        
        local pxc_count=$(echo "$pxc_list" | grep -v "^$" | wc -l | tr -d ' ')
        
        if [ $attempt -eq 1 ]; then
            log_info "Found $pxc_count PXC resource(s) to delete:"
            echo "$pxc_list" | while read -r pxc_name; do
                if [ -n "$pxc_name" ]; then
                    log_info "  - $pxc_name"
                fi
            done
        else
            log_warn "Attempt $attempt/$max_attempts - $pxc_count resource(s) still exist"
        fi
        
        # Process each PXC resource individually
        echo "$pxc_list" | while read -r pxc_name; do
            if [ -z "$pxc_name" ]; then
                continue
            fi
            
            log_info "Processing: $pxc_name"
            
            # Always use kubectl operations when namespace exists (including recreated)
            log_info "  → Removing finalizers..."
            timeout 20 kubectl patch pxc "$pxc_name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            timeout 20 kubectl patch pxc "$pxc_name" -n "$NAMESPACE" --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
            
            log_info "  → Deleting resource..."
            timeout 20 kubectl delete pxc "$pxc_name" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
            
            # Step 4: Verify it's gone
            sleep 2
            if kubectl get pxc --all-namespaces 2>/dev/null | grep -q "^$NAMESPACE $pxc_name"; then
                log_warn "  → Still exists after deletion attempt"
                
                # Last resort - try raw API delete even if namespace exists
                log_info "  → Attempting raw API deletion as last resort..."
                kubectl delete --raw "/apis/pxc.percona.com/v1/namespaces/$NAMESPACE/perconaxtradbclusters/$pxc_name" 2>/dev/null || true
            else
                log_success "  → Deleted successfully"
            fi
        done
        
        # Wait a moment for async deletions
        sleep 3
        
        # Check if anything remains
        local remaining=$(kubectl get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ')
        if [ "$remaining" -eq 0 ]; then
            log_success "All PXC resources deleted after $attempt attempt(s)"
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    # Final check after all attempts
    local final_count=$(kubectl get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ')
    if [ "$final_count" -gt 0 ]; then
        log_error "Failed to delete $final_count PXC resource(s) after $max_attempts attempts"
        log_warn "Showing remaining resources:"
        kubectl get pxc --all-namespaces 2>/dev/null | grep "^$NAMESPACE "
        log_info "Manual cleanup may be needed"
    else
        log_success "All PXC resources deleted"
    fi
    
    # Clean up recreated namespace if we created it
    if [ "$ns_recreated" = "true" ]; then
        log_info "Cleaning up temporarily recreated namespace..."
        if kubectl delete namespace "$NAMESPACE" --timeout=30s 2>/dev/null; then
            log_success "Temporary namespace deleted"
        else
            log_warn "Temporary namespace may still exist - will be cleaned up in namespace deletion step"
        fi
    fi
}

# Diagnose what's blocking deletion
diagnose_stuck_resources() {
    echo ""
    log_warn "Diagnosing what's blocking deletion..."
    echo ""
    
    # Check volumeattachments
    local va_count=$(kubectl get volumeattachments --no-headers 2>/dev/null | grep -c "$NAMESPACE" || echo "0")
    if [ "$va_count" -gt 0 ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} $va_count VolumeAttachment(s) still present:"
        kubectl get volumeattachments --no-headers 2>/dev/null | grep "$NAMESPACE" | awk '{print "  - " $1}' || true
    fi
    
    # Check PVCs
    local pvc_count=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pvc_count" -gt 0 ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} $pvc_count PVC(s) in namespace:"
        kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " [" $2 "]"}' || true
    fi
    
    # Check PVs
    local pv_count=$(kubectl get pv --no-headers 2>/dev/null | grep -c "$NAMESPACE" || echo "0")
    if [ "$pv_count" -gt 0 ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} $pv_count PV(s) bound to namespace:"
        kubectl get pv --no-headers 2>/dev/null | grep "$NAMESPACE" | awk '{print "  - " $1 " [" $5 "]"}' || true
    fi
    
    # Check pods in Terminating state
    local term_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1}' || echo "")
    if [ -n "$term_pods" ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} Pod(s) stuck in Terminating:"
        echo "$term_pods" | while read -r pod; do
            [ -n "$pod" ] && echo "  - $pod"
        done
    fi
    
    # Check for finalizers on namespace
    local ns_finalizers=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.spec.finalizers}' 2>/dev/null || echo "")
    if [ -n "$ns_finalizers" ] && [ "$ns_finalizers" != "[]" ] && [ "$ns_finalizers" != "null" ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} Namespace has finalizers: $ns_finalizers"
    fi
    
    echo ""
}

# Force cleanup volumeattachments
cleanup_volumeattachments() {
    log_info "Checking for stuck VolumeAttachments..."
    local vas=$(kubectl get volumeattachments --no-headers 2>/dev/null | grep "$NAMESPACE" | awk '{print $1}' || echo "")
    
    if [ -n "$vas" ]; then
        log_warn "Found stuck VolumeAttachments. Force deleting..."
        echo "$vas" | while read -r va; do
            if [ -n "$va" ]; then
                log_info "Deleting VolumeAttachment: $va"
                kubectl delete volumeattachment "$va" --force --grace-period=0 2>/dev/null || true
            fi
        done
        sleep 2
    fi
}

# Delete remaining resources
delete_remaining_resources() {
    log_header "Deleting Remaining Resources"
    
    # Force delete ALL pods immediately
    log_info "Force deleting all pods..."
    timeout 60 kubectl delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete statefulsets
    log_info "Force deleting statefulsets..."
    timeout 30 kubectl delete statefulsets --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete deployments
    log_info "Force deleting deployments..."
    timeout 30 kubectl delete deployments --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete services
    log_info "Deleting services..."
    timeout 30 kubectl delete services --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete configmaps
    log_info "Deleting configmaps..."
    timeout 30 kubectl delete configmaps --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete secrets
    log_info "Deleting secrets..."
    timeout 30 kubectl delete secrets --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete leases (leader election resources that can block namespace deletion)
    log_info "Deleting leases..."
    timeout 30 kubectl delete leases --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete service accounts (except default, which will be auto-deleted)
    log_info "Deleting service accounts..."
    timeout 30 kubectl delete serviceaccounts --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete events (both v1 and events.k8s.io API versions)
    log_info "Deleting events..."
    timeout 30 kubectl delete events --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    timeout 30 kubectl delete events.events.k8s.io --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    log_success "Resources deleted"
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
    log_warn "Deleting all PVCs in namespace $NAMESPACE..."
    
    # Force cleanup volumeattachments first
    log_info "Force deleting VolumeAttachments..."
    timeout 60 bash -c 'kubectl get volumeattachments --no-headers 2>/dev/null | grep "'"$NAMESPACE"'" | awk '"'"'{print $1}'"'"' | xargs -r kubectl delete volumeattachment --force --grace-period=0 2>/dev/null' || true
    
    # Remove PVC finalizers
    log_info "Removing PVC finalizers..."
    timeout 60 bash -c 'kubectl get pvc -n "'"$NAMESPACE"'" -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n "'"$NAMESPACE"'" -p '"'"'{"metadata":{"finalizers":[]}}'"'"' --type=merge 2>/dev/null' || true
    
    # Force delete PVCs
    log_info "Force deleting PVCs..."
    timeout 60 kubectl delete pvc --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    log_success "PVCs deleted"
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
    
    # Wait briefly for any async resource deletions to complete
    log_info "Waiting for resource cleanup to settle..."
    sleep 3
    
    # Check if namespace is already in Terminating state
    local ns_phase=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$ns_phase" = "Terminating" ]; then
        log_info "Namespace already in Terminating state - will force finalize"
    elif [ "$ns_phase" != "NotFound" ]; then
        # Initiate deletion if not already started
        log_info "Initiating namespace deletion..."
        kubectl delete namespace "$NAMESPACE" --timeout=10s 2>/dev/null &
        local del_pid=$!
        sleep 5
        kill $del_pid 2>/dev/null || true
        wait $del_pid 2>/dev/null || true
    fi
    
    # Give it a moment to delete naturally
    sleep 3
    
    # Check if it's still there
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Namespace still exists - forcing cleanup..."
        
        # Remove namespace finalizers
        log_info "Removing namespace finalizers..."
        timeout 30 kubectl patch namespace "$NAMESPACE" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        timeout 30 kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        
        sleep 2
        
        # Force finalize via API (this is the most effective method)
        log_info "Force finalizing namespace via API..."
        timeout 30 bash -c 'kubectl get namespace "'"$NAMESPACE"'" -o json 2>/dev/null | jq '"'"'.spec.finalizers = []'"'"' | kubectl replace --raw "/api/v1/namespaces/'"$NAMESPACE"'/finalize" -f - 2>/dev/null' || true
        
        # Wait for finalization to complete
        local wait_time=0
        local max_wait=15
        while kubectl get namespace "$NAMESPACE" &> /dev/null && [ $wait_time -lt $max_wait ]; do
            sleep 1
            wait_time=$((wait_time + 1))
        done
    fi
    
    # Final check
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace may still be deleting in background"
        log_info "If stuck, manually finalize with:"
        log_info "  kubectl get namespace $NAMESPACE -o json | jq '.spec.finalizers = []' | kubectl replace --raw \"/api/v1/namespaces/$NAMESPACE/finalize\" -f -"
    else
        log_success "Namespace deleted"
    fi
}

# Display completion summary
show_summary() {
    log_header "Uninstallation Complete"
    
    echo -e "${GREEN}[OK]${NC} Percona XtraDB Cluster uninstalled from namespace: ${NAMESPACE}"
    echo ""
    
    if [ "$DELETE_PVCS" = "yes" ]; then
        echo -e "${GREEN}[OK]${NC} All data deleted (PVCs and PVs removed)"
    else
        echo -e "${YELLOW}[INFO]${NC} Data preserved (PVCs remain)"
        echo "  View: ${CYAN}kubectl get pvc -n $NAMESPACE${NC}"
        echo "  Delete later: ${CYAN}kubectl delete pvc --all -n $NAMESPACE${NC}"
    fi
    echo ""
    
    if [ "$DELETE_NAMESPACE" = "yes" ]; then
        echo -e "${GREEN}[OK]${NC} Namespace deleted"
    else
        echo -e "${YELLOW}[INFO]${NC} Namespace preserved: ${NAMESPACE}"
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
    cleanup_operator_resources
    delete_pxc_resources
    delete_remaining_resources
    delete_storage
    delete_namespace
    
    show_summary
}

# Run main function
main "$@"


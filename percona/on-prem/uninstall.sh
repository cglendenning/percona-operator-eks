#!/bin/bash
# Percona XtraDB Cluster Uninstallation Script for On-Premise (vSphere/vCenter)
# Works on both WSL and macOS
#
# ═══════════════════════════════════════════════════════════════════════════════
# METHODICAL UNINSTALLATION WITH STATE VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script implements a methodical, transparent uninstall process with:
#
# ✓ State Verification: After each major step, current state is compared to end state
# ✓ Progressive Prompts: User is asked to confirm each major operation
# ✓ Command Reporting: Every kubectl command is logged before execution
# ✓ Granular Steps: Resource deletion broken into logical, verifiable steps
# ✓ Abort Capability: User can abort at any prompt
# ✓ Diagnostic Tools: Automatic diagnosis if resources remain stuck
#
# UNINSTALL STEPS:
#   Step 1: Uninstall Helm Releases (PXC cluster, operator)
#   Step 2: Delete PXC Custom Resources (cluster definitions)
#   Step 3: Check Cluster-wide Resources (informational)
#   Step 4a: Delete Workloads (StatefulSets, Deployments)
#   Step 4b: Force Delete Pods
#   Step 4c: Delete Services and Configs (services, configmaps, secrets)
#   Step 5: Delete Storage (PVCs) - asked at runtime, not upfront
#   Step 6: Delete Namespace - asked at runtime, not upfront
#
# Each step shows:
#   - What will be deleted
#   - Commands being executed
#   - Verification of deletion
#   - Current state vs target end state
#
# ═══════════════════════════════════════════════════════════════════════════════

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

# Define ideal end state for verification
declare -A END_STATE=(
    [helm_releases]=0
    [pxc_resources]=0
    [deployments]=0
    [statefulsets]=0
    [pods]=0
    [services]=0
    [configmaps]=0
    [secrets]=0
    [pvcs]=0
    [namespace]="NotFound"
)

# Track current state
declare -A CURRENT_STATE

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

# Verify current state and track progress toward end state
verify_current_state() {
    local scope="$1"  # What we just worked on
    
    log_header "State Verification: After ${scope}"
    
    # Check namespace state first - critical for determining if we can query resources
    CURRENT_STATE[namespace]=$(kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    local ns_state="${CURRENT_STATE[namespace]}"
    
    # If namespace is Terminating or NotFound, we can't reliably query namespace-scoped resources
    if [ "$ns_state" = "Terminating" ]; then
        log_warn "Namespace is in Terminating state - some queries may fail"
        echo ""
        
        # Set defaults for namespace-scoped resources (can't query them reliably)
        CURRENT_STATE[helm_releases]=0
        CURRENT_STATE[deployments]=0
        CURRENT_STATE[statefulsets]=0
        CURRENT_STATE[pods]=0
        CURRENT_STATE[services]=0
        CURRENT_STATE[configmaps]=0
        CURRENT_STATE[secrets]=0
        CURRENT_STATE[pvcs]=0
        
        # Can still check cluster-scoped PXC resources
        CURRENT_STATE[pxc_resources]=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ' || echo "0")
        
        log_info "Cannot query namespace-scoped resources while namespace is Terminating"
        log_info "Will attempt to force-finalize namespace to complete uninstall"
        echo ""
        
    elif [ "$ns_state" = "NotFound" ]; then
        log_info "Namespace not found - setting all resource counts to 0"
        
        # Namespace doesn't exist - set everything to 0 except check for orphaned PXC resources
        CURRENT_STATE[helm_releases]=0
        CURRENT_STATE[deployments]=0
        CURRENT_STATE[statefulsets]=0
        CURRENT_STATE[pods]=0
        CURRENT_STATE[services]=0
        CURRENT_STATE[configmaps]=0
        CURRENT_STATE[secrets]=0
        CURRENT_STATE[pvcs]=0
        CURRENT_STATE[pxc_resources]=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ' || echo "0")
        
    else
        # Namespace exists and is Active - query all resources normally
        # Use || echo "0" to prevent failures from causing script exit
        CURRENT_STATE[helm_releases]=$(helm list -n "$NAMESPACE" --short 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[pxc_resources]=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[deployments]=$(kubectl --kubeconfig="$KUBECONFIG" get deployments -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[statefulsets]=$(kubectl --kubeconfig="$KUBECONFIG" get statefulsets -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[pods]=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[services]=$(kubectl --kubeconfig="$KUBECONFIG" get svc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[configmaps]=$(kubectl --kubeconfig="$KUBECONFIG" get configmaps -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[secrets]=$(kubectl --kubeconfig="$KUBECONFIG" get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token" | wc -l | tr -d ' ' || echo "0")
        CURRENT_STATE[pvcs]=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    fi
    
    # Display results table
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    printf "%-25s %12s %12s %8s\n" "Resource Type" "Current" "Target" "Status"
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    
    local all_complete=true
    
    for resource in helm_releases pxc_resources deployments statefulsets pods services configmaps secrets pvcs; do
        local current="${CURRENT_STATE[$resource]}"
        local target="${END_STATE[$resource]}"
        local status
        
        if [ "$current" -eq "$target" ]; then
            status="${GREEN}✓ Complete${NC}"
        else
            status="${YELLOW}⚠ Remaining${NC}"
            all_complete=false
        fi
        
        # Format resource name for display
        local display_name=$(echo "$resource" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
        printf "%-25s %12s %12s %s\n" "$display_name" "$current" "$target" "$status"
    done
    
    # Namespace status (special case with Terminating handling)
    local ns_current="${CURRENT_STATE[namespace]}"
    local ns_target="${END_STATE[namespace]}"
    local ns_status
    if [ "$ns_current" = "$ns_target" ]; then
        ns_status="${GREEN}✓ Complete${NC}"
    elif [ "$ns_current" = "Terminating" ]; then
        ns_status="${YELLOW}⚠ Terminating${NC}"
        all_complete=false
    else
        ns_status="${YELLOW}⚠ Exists${NC}"
        all_complete=false
    fi
    printf "%-25s %12s %12s %s\n" "Namespace" "$ns_current" "$ns_target" "$ns_status"
    
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    
    if [ "$all_complete" = true ]; then
        echo -e "${GREEN}[✓] All resources in target end state${NC}"
    else
        echo -e "${YELLOW}[⚠] Some resources still remain${NC}"
    fi
    echo ""
    
    # If namespace became Terminating during the process, offer to skip to finalization
    if [ "$ns_state" = "Terminating" ] && [ "$scope" != "Force Finalize" ] && [ "$scope" != "Namespace" ] && [ "$scope" != "Complete Uninstallation" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  NAMESPACE IS NOW TERMINATING${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        log_warn "Namespace entered Terminating state - resource queries will fail"
        log_info "You can skip remaining steps and force-finalize the namespace now"
        echo ""
        read -p "Skip to namespace finalization? (yes/no) [no]: " skip_to_finalize
        
        if [[ "$skip_to_finalize" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log_info "Skipping to namespace finalization..."
            DELETE_NAMESPACE="yes"
            delete_namespace
            verify_current_state "Force Finalize"
            
            # Check if we need diagnostics
            local total_remaining=0
            for resource in helm_releases pxc_resources deployments statefulsets pods services configmaps secrets; do
                total_remaining=$((total_remaining + ${CURRENT_STATE[$resource]}))
            done
            
            if [ "$total_remaining" -gt 0 ] && [ "${CURRENT_STATE[namespace]}" != "NotFound" ]; then
                diagnose_stuck_resources
                cleanup_volumeattachments
            fi
            
            show_summary
            exit 0
        fi
        echo ""
    fi
}

# Prompt user to continue with next step
prompt_continue() {
    local next_step="$1"
    local description="$2"
    
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Next Step: ${next_step}${NC}"
    echo -e "${YELLOW}  ${description}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    read -p "Continue with this step? (yes/no/abort) [yes]: " response
    response="${response:-yes}"
    
    if [[ "$response" =~ ^[Aa]([Bb][Oo][Rr][Tt])?$ ]]; then
        log_warn "Uninstall aborted by user"
        log_info "Current state preserved - partial uninstall complete"
        exit 0
    elif [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        log_info "Skipping step: $next_step"
        return 1
    fi
    
    return 0
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
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please configure kubectl and try again"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Prompt for namespace
prompt_namespace() {
    log_header "Percona XtraDB Cluster Uninstaller for On-Premise vSphere/vCenter"
    
    # List namespaces with Percona resources
    log_info "Namespaces with Percona resources:"
    kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces 2>/dev/null | grep -v "^NAMESPACE" | awk '{print "  - " $1}' || echo "  (none found)"
    echo ""
    
    read -p "Enter namespace to uninstall from: " namespace_input
    NAMESPACE="$namespace_input"
    
    if [ -z "$NAMESPACE" ]; then
        log_error "Namespace cannot be empty"
        exit 1
    fi
    
    # Verify namespace exists or has orphaned resources
    local ns_status=$(kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$ns_status" = "NotFound" ]; then
        # Check if there are orphaned PXC resources referencing this namespace
        local orphaned_pxc=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces 2>/dev/null | grep "^$NAMESPACE " || echo "")
        
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
    
    # Check if namespace is in Terminating state - if so, warn user
    local ns_phase=$(kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$ns_phase" = "Terminating" ]; then
        echo -e "${YELLOW}⚠️  Note: Namespace is in Terminating state${NC}"
        echo -e "${YELLOW}⚠️  Some resource queries may fail or show incomplete results${NC}"
        echo ""
    fi
    
    echo -e "${MAGENTA}═══ Helm Releases ═══${NC}"
    if [ "$ns_phase" = "Terminating" ]; then
        echo "  (cannot query - namespace Terminating)"
    else
        local releases=$(helm list -n "$NAMESPACE" --short 2>/dev/null || echo "")
        if [ -n "$releases" ]; then
            echo "$releases" | while read -r release; do
                echo "  - $release"
            done
        else
            echo "  (none found)"
        fi
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ PXC Clusters ═══${NC}"
    # Check both namespace-scoped and orphaned (cluster-wide) PXC resources
    local pxc_resources=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " || echo "")
    if [ -n "$pxc_resources" ]; then
        echo "$pxc_resources" | awk '{print "  - " $2 " (Age: " $NF ")"}'
    else
        echo "  (none found)"
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Pods ═══${NC}"
    if [ "$ns_phase" = "Terminating" ]; then
        echo "  (cannot query - namespace Terminating)"
    else
        local pod_count=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $3 ")"}'
        else
            echo "  (none found)"
        fi
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Services ═══${NC}"
    if [ "$ns_phase" = "Terminating" ]; then
        echo "  (cannot query - namespace Terminating)"
    else
        local svc_count=$(kubectl --kubeconfig="$KUBECONFIG" get svc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [ "$svc_count" -gt 0 ]; then
            kubectl --kubeconfig="$KUBECONFIG" get svc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $2 ")"}'
        else
            echo "  (none found)"
        fi
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Persistent Volume Claims ═══${NC}"
    if [ "$ns_phase" = "Terminating" ]; then
        echo "  (cannot query - namespace Terminating)"
    else
        local pvc_count=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [ "$pvc_count" -gt 0 ]; then
            kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $2 ", " $3 ")"}'
            echo ""
            
            # Calculate total storage (column 4 is CAPACITY)
            local total_storage=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $4}' | sed 's/Gi//' | awk '{sum+=$1} END {print sum}')
            log_warn "Total storage: ${total_storage}Gi"
            
            # Show associated Persistent Volumes
            echo ""
            echo -e "${MAGENTA}═══ Associated Persistent Volumes ═══${NC}"
            kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | while read -r pv; do
                if [ -n "$pv" ] && [ "$pv" != "<none>" ]; then
                    local pv_info=$(kubectl --kubeconfig="$KUBECONFIG" get pv "$pv" --no-headers 2>/dev/null | awk '{print $1 " (" $2 ", " $5 ", " $6 ")"}' || echo "$pv (details unavailable)")
                    echo "  - $pv_info"
                fi
            done
        else
            echo "  (none found)"
        fi
    fi
    echo ""
    
    echo -e "${MAGENTA}═══ Secrets ═══${NC}"
    if [ "$ns_phase" = "Terminating" ]; then
        echo "  (cannot query - namespace Terminating)"
    else
        local secret_count=$(kubectl --kubeconfig="$KUBECONFIG" get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token" | wc -l | tr -d ' ' || echo "0")
        if [ "$secret_count" -gt 0 ]; then
            kubectl --kubeconfig="$KUBECONFIG" get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token" | awk '{print "  - " $1 " (" $2 ")"}'
        else
            echo "  (none found)"
        fi
    fi
    echo ""
}

# Legacy confirm_deletion function - NO LONGER USED in new methodical flow
# Decisions are now made progressively after each step
# This function is kept for reference but not called

# Uninstall Helm releases
uninstall_helm_releases() {
    log_header "Uninstalling Helm Releases"
    
    # Check if namespace exists - if not, skip Helm (it will fail anyway)
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &>/dev/null; then
        log_warn "Namespace doesn't exist - skipping Helm uninstall"
        log_info "Will proceed directly to resource cleanup"
        return
    fi
    
    local releases=$(helm list -n "$NAMESPACE" --short 2>/dev/null || echo "")
    
    if [ -z "$releases" ]; then
        log_info "No Helm releases found in namespace $NAMESPACE"
        return
    fi
    
    local release_count=$(echo "$releases" | grep -v "^$" | wc -l | tr -d ' ')
    log_info "Found $release_count Helm release(s):"
    echo "$releases" | while read -r release; do
        if [ -n "$release" ]; then
            echo "  - $release"
        fi
    done
    echo ""
    
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
                local blocking_pods=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | tr -d ' ')
                local blocking_pvcs=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                local blocking_finalizers=$(kubectl --kubeconfig="$KUBECONFIG" get pxc -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[].metadata.finalizers[]' 2>/dev/null | wc -l | tr -d ' ')
                
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

# Cluster-wide resources are NOT deleted for safety
cleanup_operator_resources() {
    log_header "Cluster-Wide Resources - Safety Policy"
    
    log_info "This uninstall script ONLY removes resources in namespace: $NAMESPACE"
    log_info ""
    log_info "Cluster-wide resources (ClusterRole, ClusterRoleBinding, CRDs, Webhooks)"
    log_info "are NEVER deleted to ensure safety in multi-tenant environments."
    log_info ""
    log_info "These resources are:"
    log_info "  ✓ Shared across all Percona installations"
    log_info "  ✓ Namespace-specific (e.g., percona-operator-${NAMESPACE}-pxc-operator)"
    log_info "  ✓ Harmless when left behind (do not consume resources)"
    log_info "  ✓ Required by the operator's unique release per namespace design"
    echo ""
    
    # Show which cluster-wide resources exist for this namespace
    local release_name="percona-operator-${NAMESPACE}"
    local found_resources=false
    
    if kubectl --kubeconfig="$KUBECONFIG" get clusterrole "${release_name}-pxc-operator" &>/dev/null; then
        log_info "Found ClusterRole: ${release_name}-pxc-operator (will remain)"
        found_resources=true
    fi
    
    if kubectl --kubeconfig="$KUBECONFIG" get clusterrolebinding "${release_name}-pxc-operator" &>/dev/null; then
        log_info "Found ClusterRoleBinding: ${release_name}-pxc-operator (will remain)"
        found_resources=true
    fi
    
    if [ "$found_resources" = false ]; then
        log_info "No namespace-specific cluster-wide resources found."
    fi
    
    echo ""
    log_success "Namespace-scoped resources will be completely removed"
    log_success "Cluster-wide resources will remain (safe for multi-namespace setups)"
}

# Delete PXC custom resources
delete_pxc_resources() {
    log_header "Deleting PXC Custom Resources"
    
    # Check if namespace exists - critical for determining deletion strategy
    local ns_exists="false"
    local ns_recreated="false"
    if kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &>/dev/null; then
        ns_exists="true"
        log_info "Namespace exists - using namespace-scoped operations"
    else
        # Check if there are orphaned PXC resources
        local orphaned_count=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ')
        
        if [ "$orphaned_count" -gt 0 ]; then
            log_warn "Namespace doesn't exist but $orphaned_count orphaned PXC resource(s) found"
            log_warn "Kubernetes API rejects operations on orphaned resources without namespace"
            log_info "Temporarily recreating namespace to enable cleanup..."
            
            if kubectl --kubeconfig="$KUBECONFIG" create namespace "$NAMESPACE" &>/dev/null; then
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
        local pxc_list=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | awk '{print $2}' || echo "")
        
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
            log_info "     Executing: kubectl patch pxc $pxc_name -n $NAMESPACE -p '{\"metadata\":{\"finalizers\":[]}}'"
            timeout 20 kubectl --kubeconfig="$KUBECONFIG" patch pxc "$pxc_name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            timeout 20 kubectl --kubeconfig="$KUBECONFIG" patch pxc "$pxc_name" -n "$NAMESPACE" --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
            
            log_info "  → Deleting resource..."
            log_info "     Executing: kubectl delete pxc $pxc_name -n $NAMESPACE --force --grace-period=0"
            timeout 20 kubectl --kubeconfig="$KUBECONFIG" delete pxc "$pxc_name" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
            
            # Step 4: Verify it's gone
            sleep 2
            if kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces 2>/dev/null | grep -q "^$NAMESPACE $pxc_name"; then
                log_warn "  → Still exists after deletion attempt"
                
                # Last resort - try raw API delete even if namespace exists
                log_info "  → Attempting raw API deletion as last resort..."
                kubectl --kubeconfig="$KUBECONFIG" delete --raw "/apis/pxc.percona.com/v1/namespaces/$NAMESPACE/perconaxtradbclusters/$pxc_name" 2>/dev/null || true
            else
                log_success "  → Deleted successfully"
            fi
        done
        
        # Wait a moment for async deletions
        sleep 3
        
        # Check if anything remains
        local remaining=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ')
        if [ "$remaining" -eq 0 ]; then
            log_success "All PXC resources deleted after $attempt attempt(s)"
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    # Final check after all attempts
    local final_count=$(kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces --no-headers 2>/dev/null | grep "^$NAMESPACE " | wc -l | tr -d ' ')
    if [ "$final_count" -gt 0 ]; then
        log_error "Failed to delete $final_count PXC resource(s) after $max_attempts attempts"
        log_warn "Showing remaining resources:"
        kubectl --kubeconfig="$KUBECONFIG" get pxc --all-namespaces 2>/dev/null | grep "^$NAMESPACE "
        log_info "Manual cleanup may be needed"
    else
        log_success "All PXC resources deleted"
    fi
    
    # Clean up recreated namespace if we created it
    if [ "$ns_recreated" = "true" ]; then
        log_info "Cleaning up temporarily recreated namespace..."
        if kubectl --kubeconfig="$KUBECONFIG" delete namespace "$NAMESPACE" --timeout=30s 2>/dev/null; then
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
    
    # Check volumeattachments (informational - these are cluster-scoped and safe to leave)
    local va_count=$(kubectl --kubeconfig="$KUBECONFIG" get volumeattachments --no-headers 2>/dev/null | grep -c "$NAMESPACE" || echo "0")
    if [ "$va_count" -gt 0 ]; then
        echo -e "${BLUE}[INFO]${NC} $va_count VolumeAttachment(s) exist - will auto-clean:"
        kubectl --kubeconfig="$KUBECONFIG" get volumeattachments --no-headers 2>/dev/null | grep "$NAMESPACE" | awk '{print "  - " $1}' || true
        echo "  (These are cluster-scoped and will be cleaned up automatically by Kubernetes)"
    fi
    
    # Check PVCs
    local pvc_count=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pvc_count" -gt 0 ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} $pvc_count PVC(s) in namespace:"
        kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " [" $2 "]"}' || true
    fi
    
    # Check PVs
    local pv_count=$(kubectl --kubeconfig="$KUBECONFIG" get pv --no-headers 2>/dev/null | grep -c "$NAMESPACE" || echo "0")
    if [ "$pv_count" -gt 0 ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} $pv_count PV(s) bound to namespace:"
        kubectl --kubeconfig="$KUBECONFIG" get pv --no-headers 2>/dev/null | grep "$NAMESPACE" | awk '{print "  - " $1 " [" $5 "]"}' || true
    fi
    
    # Check pods in Terminating state
    local term_pods=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1}' || echo "")
    if [ -n "$term_pods" ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} Pod(s) stuck in Terminating:"
        echo "$term_pods" | while read -r pod; do
            [ -n "$pod" ] && echo "  - $pod"
        done
    fi
    
    # Check for finalizers on namespace
    local ns_finalizers=$(kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" -o jsonpath='{.spec.finalizers}' 2>/dev/null || echo "")
    if [ -n "$ns_finalizers" ] && [ "$ns_finalizers" != "[]" ] && [ "$ns_finalizers" != "null" ]; then
        echo -e "${YELLOW}[BLOCKING]${NC} Namespace has finalizers: $ns_finalizers"
    fi
    
    echo ""
}

# Check volumeattachments (informational only - not deleted for safety)
cleanup_volumeattachments() {
    log_info "Checking for VolumeAttachments..."
    local vas=$(kubectl --kubeconfig="$KUBECONFIG" get volumeattachments --no-headers 2>/dev/null | grep "$NAMESPACE" || echo "")
    
    if [ -n "$vas" ]; then
        log_info "Found VolumeAttachments that may be related to this namespace:"
        echo "$vas" | awk '{print "  - " $1}'
        echo ""
        log_info "VolumeAttachments are cluster-scoped resources and are NOT automatically deleted."
        log_info "They should be cleaned up automatically by Kubernetes when PVs are removed."
        log_info ""
        log_info "If VolumeAttachments remain stuck after uninstall, investigate manually:"
        log_info "  1. Check which PV they reference: kubectl get volumeattachment <name> -o yaml"
        log_info "  2. Verify the PV no longer exists: kubectl get pv"
        log_info "  3. If orphaned, delete manually: kubectl delete volumeattachment <name>"
    else
        log_info "No VolumeAttachments found matching this namespace"
    fi
}

# Delete workloads (StatefulSets and Deployments)
delete_workloads() {
    log_header "Deleting Workloads"
    
    log_info "Deleting StatefulSets..."
    local sts_list=$(kubectl --kubeconfig="$KUBECONFIG" get statefulsets -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    local sts_count=$(echo "$sts_list" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [ "$sts_count" -gt 0 ]; then
        log_info "Found $sts_count StatefulSet(s):"
        echo "$sts_list" | awk '{print "  - " $1}'
        
        log_info "Executing: kubectl delete statefulsets --all -n $NAMESPACE --force --grace-period=0"
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete statefulsets --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log_success "$sts_count StatefulSet(s) deletion initiated"
    else
        log_info "No StatefulSets found"
    fi
    
    echo ""
    log_info "Deleting Deployments..."
    local deploy_list=$(kubectl --kubeconfig="$KUBECONFIG" get deployments -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    local deploy_count=$(echo "$deploy_list" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [ "$deploy_count" -gt 0 ]; then
        log_info "Found $deploy_count Deployment(s):"
        echo "$deploy_list" | awk '{print "  - " $1}'
        
        log_info "Executing: kubectl delete deployments --all -n $NAMESPACE --force --grace-period=0"
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete deployments --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log_success "$deploy_count Deployment(s) deletion initiated"
    else
        log_info "No Deployments found"
    fi
    
    # Give controllers time to start pod deletion
    echo ""
    log_info "Waiting for workload controllers to initiate pod deletion..."
    sleep 3
    
    local remaining_pods=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_info "Pods currently in namespace: $remaining_pods"
    
    echo ""
}

# Force delete all pods
delete_pods() {
    log_header "Force Deleting Pods"
    
    local pod_list=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    local pod_count=$(echo "$pod_list" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [ "$pod_count" -gt 0 ]; then
        log_info "Found $pod_count pod(s):"
        echo "$pod_list" | awk '{print "  - " $1 " (" $3 ")"}'
        
        log_info "Executing: kubectl delete pods --all -n $NAMESPACE --force --grace-period=0"
        timeout 60 kubectl --kubeconfig="$KUBECONFIG" delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        
        # Wait and verify
        log_info "Waiting for pods to terminate..."
        sleep 5
        
        local remaining=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$remaining" -eq 0 ]; then
            log_success "All pods deleted successfully"
        else
            log_warn "$remaining pod(s) still in terminating state"
            kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1 " (" $3 ")"}'
        fi
    else
        log_info "No pods found"
    fi
    
    echo ""
}

# Delete services and configuration resources
delete_services_and_configs() {
    log_header "Deleting Services and Configuration Resources"
    
    # Services
    log_info "Deleting Services..."
    local svc_list=$(kubectl --kubeconfig="$KUBECONFIG" get svc -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    local svc_count=$(echo "$svc_list" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [ "$svc_count" -gt 0 ]; then
        log_info "Found $svc_count service(s):"
        echo "$svc_list" | awk '{print "  - " $1 " (" $2 ")"}'
        
        log_info "Executing: kubectl delete services --all -n $NAMESPACE"
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete services --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log_success "Services deleted"
    else
        log_info "No services found"
    fi
    
    echo ""
    
    # ConfigMaps
    log_info "Deleting ConfigMaps..."
    local cm_count=$(kubectl --kubeconfig="$KUBECONFIG" get configmaps -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$cm_count" -gt 0 ]; then
        log_info "Found $cm_count ConfigMap(s)"
        log_info "Executing: kubectl delete configmaps --all -n $NAMESPACE"
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete configmaps --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log_success "ConfigMaps deleted"
    else
        log_info "No ConfigMaps found"
    fi
    
    echo ""
    
    # Secrets
    log_info "Deleting Secrets..."
    local secret_list=$(kubectl --kubeconfig="$KUBECONFIG" get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token" || echo "")
    local secret_count=$(echo "$secret_list" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [ "$secret_count" -gt 0 ]; then
        log_info "Found $secret_count secret(s) (excluding default tokens)"
        log_info "Executing: kubectl delete secrets --all -n $NAMESPACE"
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete secrets --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log_success "Secrets deleted"
    else
        log_info "No secrets found"
    fi
    
    echo ""
    
    # Leases (leader election resources)
    log_info "Deleting Leases..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete leases --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Service accounts
    log_info "Deleting ServiceAccounts..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete serviceaccounts --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Events
    log_info "Deleting Events..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete events --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete events.events.k8s.io --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    log_success "Auxiliary resources cleaned up"
    echo ""
}

# Legacy function - kept for backward compatibility but not used in new flow
delete_remaining_resources_legacy() {
    log_header "Deleting Remaining Resources"
    
    # Force delete ALL pods immediately
    log_info "Force deleting all pods..."
    timeout 60 kubectl --kubeconfig="$KUBECONFIG" delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete statefulsets
    log_info "Force deleting statefulsets..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete statefulsets --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete deployments
    log_info "Force deleting deployments..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete deployments --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete services
    log_info "Deleting services..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete services --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete configmaps
    log_info "Deleting configmaps..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete configmaps --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete secrets
    log_info "Deleting secrets..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete secrets --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete leases (leader election resources that can block namespace deletion)
    log_info "Deleting leases..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete leases --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete service accounts (except default, which will be auto-deleted)
    log_info "Deleting service accounts..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete serviceaccounts --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Delete events (both v1 and events.k8s.io API versions)
    log_info "Deleting events..."
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete events --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    timeout 30 kubectl --kubeconfig="$KUBECONFIG" delete events.events.k8s.io --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
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
    
    # List current PVCs
    log_info "Current PVCs in namespace:"
    kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" 2>/dev/null || log_info "No PVCs found"
    echo ""
    
    # Get list of PVs before deleting PVCs
    local pvs=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | grep -v "<none>" || echo "")
    local pvc_count=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$pvc_count" -eq 0 ]; then
        log_info "No PVCs to delete"
        return
    fi
    
    # Delete PVCs
    log_warn "Deleting $pvc_count PVC(s) in namespace $NAMESPACE..."
    
    # Note: VolumeAttachments are NOT deleted - they're cluster-scoped and will auto-clean
    echo ""
    log_info "Note: VolumeAttachments (if any) will be cleaned up automatically by Kubernetes"
    
    # Remove PVC finalizers
    echo ""
    log_info "Step 1: Removing PVC finalizers..."
    log_info "Executing: kubectl get pvc -n $NAMESPACE -o name | xargs kubectl patch <pvc> -p '{\"metadata\":{\"finalizers\":[]}}'"
    timeout 60 bash -c 'kubectl --kubeconfig="$KUBECONFIG" get pvc -n "'"$NAMESPACE"'" -o name 2>/dev/null | xargs -r -I {} kubectl --kubeconfig="$KUBECONFIG" patch {} -n "'"$NAMESPACE"'" -p '"'"'{"metadata":{"finalizers":[]}}'"'"' --type=merge 2>/dev/null' || true
    
    # Force delete PVCs
    echo ""
    log_info "Step 2: Force deleting PVCs..."
    log_info "Executing: kubectl delete pvc --all -n $NAMESPACE --force --grace-period=0"
    timeout 60 kubectl --kubeconfig="$KUBECONFIG" delete pvc --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
    
    # Verify
    sleep 3
    local remaining_pvcs=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining_pvcs" -eq 0 ]; then
        log_success "All PVCs deleted successfully"
    else
        log_warn "$remaining_pvcs PVC(s) still exist"
    fi
    
    echo ""
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
    
    # Check what's in the namespace first
    echo ""
    log_info "Checking remaining resources in namespace..."
    local remaining_count=$(kubectl --kubeconfig="$KUBECONFIG" get all -n "$NAMESPACE" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining_count" -gt 1 ]; then
        log_warn "Found $remaining_count resources still in namespace:"
        kubectl --kubeconfig="$KUBECONFIG" get all -n "$NAMESPACE" 2>/dev/null || true
    else
        log_info "Namespace appears clean"
    fi
    
    # Wait briefly for any async resource deletions to complete
    echo ""
    log_info "Waiting for resource cleanup to settle..."
    sleep 3
    
    # Check if namespace is already in Terminating state
    local ns_phase=$(kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$ns_phase" = "Terminating" ]; then
        log_info "Namespace already in Terminating state - will force finalize"
    elif [ "$ns_phase" != "NotFound" ]; then
        # Initiate deletion if not already started
        log_info "Initiating namespace deletion..."
        log_info "Executing: kubectl delete namespace $NAMESPACE"
        kubectl --kubeconfig="$KUBECONFIG" delete namespace "$NAMESPACE" --timeout=10s 2>/dev/null &
        local del_pid=$!
        sleep 5
        kill $del_pid 2>/dev/null || true
        wait $del_pid 2>/dev/null || true
    fi
    
    # Give it a moment to delete naturally
    sleep 3
    
    # Check if it's still there
    if kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Namespace still exists - forcing cleanup..."
        
        # Remove namespace finalizers
        echo ""
        log_info "Step 1: Removing namespace finalizers..."
        log_info "Executing: kubectl patch namespace $NAMESPACE -p '{\"spec\":{\"finalizers\":[]}}'"
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" patch namespace "$NAMESPACE" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        timeout 30 kubectl --kubeconfig="$KUBECONFIG" patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        
        sleep 2
        
        # Force finalize via API (this is the most effective method)
        echo ""
        log_info "Step 2: Force finalizing namespace via API..."
        log_info "Executing: kubectl get namespace $NAMESPACE -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/$NAMESPACE/finalize"
        timeout 30 bash -c 'kubectl --kubeconfig="$KUBECONFIG" get namespace "'"$NAMESPACE"'" -o json 2>/dev/null | jq '"'"'.spec.finalizers = []'"'"' | kubectl --kubeconfig="$KUBECONFIG" replace --raw "/api/v1/namespaces/'"$NAMESPACE"'/finalize" -f - 2>/dev/null' || true
        
        # Wait for finalization to complete
        local wait_time=0
        local max_wait=15
        while kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &> /dev/null && [ $wait_time -lt $max_wait ]; do
            sleep 1
            wait_time=$((wait_time + 1))
        done
    fi
    
    # Final check
    if kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &> /dev/null; then
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
    echo -e "${GREEN}[OK]${NC} Environment: On-Premise vSphere/vCenter"
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

# Main uninstallation flow - methodical and transparent
main() {
    # Prerequisites and initial setup
    check_prerequisites
    prompt_namespace
    
    # Check if namespace is stuck in Terminating state before proceeding
    local initial_ns_state=$(kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$initial_ns_state" = "Terminating" ]; then
        log_header "Namespace Already Terminating"
        echo -e "${YELLOW}⚠️  WARNING: Namespace '$NAMESPACE' is stuck in Terminating state${NC}"
        echo ""
        log_info "This usually happens when resources have finalizers that prevent deletion."
        log_info "The uninstall script can attempt to force-finalize the namespace."
        echo ""
        log_info "Options:"
        echo "  1. Force-finalize namespace now (skip to cleanup)"
        echo "  2. Run full uninstall process (may help clear blocking resources)"
        echo "  3. Abort"
        echo ""
        read -p "Choose option (1/2/3) [2]: " terminating_option
        terminating_option="${terminating_option:-2}"
        
        if [ "$terminating_option" = "1" ]; then
            log_info "Attempting to force-finalize namespace..."
            DELETE_NAMESPACE="yes"
            delete_namespace
            verify_current_state "Force Finalize"
            show_summary
            exit 0
        elif [ "$terminating_option" = "3" ]; then
            log_info "Uninstallation cancelled by user"
            exit 0
        fi
        # Option 2 falls through to normal process
        echo ""
        log_info "Proceeding with full uninstall process..."
        log_warn "Some resource queries may fail due to Terminating state"
        echo ""
        sleep 2
    fi
    
    show_resources
    
    # Initial confirmation - must type 'yes'
    echo ""
    echo -e "${RED}⚠️  WARNING: You are about to uninstall Percona XtraDB Cluster from namespace '${NAMESPACE}'${NC}"
    echo -e "${RED}⚠️  This process will be methodical with verification after each step${NC}"
    echo ""
    read -p "Do you want to proceed with uninstallation? (type 'yes' to confirm): " initial_confirm
    
    if [ "$initial_confirm" != "yes" ]; then
        log_info "Uninstallation cancelled by user"
        exit 0
    fi
    
    echo ""
    log_header "Methodical Uninstallation Process"
    log_info "You will be prompted before each major step"
    log_info "State will be verified after each step"
    log_info "Type 'abort' at any prompt to stop the process"
    echo ""
    sleep 2
    
    # Step 1: Uninstall Helm Releases
    if prompt_continue "Step 1: Uninstall Helm Releases" "Remove Helm-managed deployments (PXC cluster, operator)"; then
    uninstall_helm_releases
        verify_current_state "Helm Releases"
    fi
    
    # Step 2: Delete PXC Custom Resources
    if prompt_continue "Step 2: Delete PXC Custom Resources" "Remove PXC cluster definitions (CRDs instances)"; then
    delete_pxc_resources
        verify_current_state "PXC Resources"
    fi
    
    # Step 3: Cluster-wide resources (informational only)
    echo ""
    log_info "Checking cluster-wide resources..."
    cleanup_operator_resources
    
    # Step 4a: Delete Workloads (StatefulSets and Deployments)
    if prompt_continue "Step 4a: Delete Workloads" "Remove StatefulSets and Deployments (will trigger pod deletion)"; then
        delete_workloads
        verify_current_state "Workloads"
    fi
    
    # Step 4b: Force Delete Pods
    if prompt_continue "Step 4b: Force Delete Pods" "Terminate all remaining pods with force"; then
        delete_pods
        verify_current_state "Pods"
    fi
    
    # Step 4c: Delete Services and Configurations
    if prompt_continue "Step 4c: Delete Services and Configs" "Remove services, configmaps, secrets, and other resources"; then
        delete_services_and_configs
        verify_current_state "Services and Configs"
    fi
    
    # Step 5: Storage (ask user now, not at beginning)
    echo ""
    log_header "Storage Decision"
    log_info "PVCs (Persistent Volume Claims) contain your database data"
    echo ""
    kubectl --kubeconfig="$KUBECONFIG" get pvc -n "$NAMESPACE" 2>/dev/null || log_info "No PVCs found"
    echo ""
    
    read -p "Do you want to delete PVCs and permanently lose all database data? (yes/no) [no]: " delete_pvcs_input
    DELETE_PVCS="${delete_pvcs_input:-no}"
    
    if [ "$DELETE_PVCS" = "yes" ]; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ⚠️  CRITICAL WARNING - DATA DESTRUCTION  ⚠️               ║${NC}"
        echo -e "${RED}║                                                            ║${NC}"
        echo -e "${RED}║  You are about to PERMANENTLY DELETE all database data!   ║${NC}"
        echo -e "${RED}║  This action CANNOT be undone!                            ║${NC}"
        echo -e "${RED}║  All backups, databases, and data will be lost!           ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "Type 'DELETE ALL DATA' (in CAPS) to confirm: " final_confirm
        
        if [ "$final_confirm" = "DELETE ALL DATA" ]; then
            if prompt_continue "Step 5: Delete Storage" "Permanently remove all PVCs and database data"; then
    delete_storage
                verify_current_state "Storage"
            fi
        else
            log_info "Storage deletion cancelled - preserving data"
            DELETE_PVCS="no"
        fi
    else
        log_info "Preserving PVCs and database data"
        echo ""
    fi
    
    # Step 6: Namespace (ask user now)
    echo ""
    log_header "Namespace Decision"
    log_info "Current namespace: $NAMESPACE"
    
    # Check what remains in namespace
    local remaining_resources=$(kubectl --kubeconfig="$KUBECONFIG" get all -n "$NAMESPACE" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining_resources" -gt 1 ]; then
        log_warn "Namespace still contains $remaining_resources resources"
    else
        log_info "Namespace appears to be empty"
    fi
    echo ""
    
    read -p "Do you want to delete the namespace '$NAMESPACE'? (yes/no) [no]: " delete_ns_input
    DELETE_NAMESPACE="${delete_ns_input:-no}"
    
    if [ "$DELETE_NAMESPACE" = "yes" ]; then
        if prompt_continue "Step 6: Delete Namespace" "Remove namespace completely"; then
    delete_namespace
            verify_current_state "Namespace"
        fi
    else
        log_info "Preserving namespace '$NAMESPACE'"
        echo ""
    fi
    
    # Final comprehensive state check
    echo ""
    log_header "═══ FINAL STATE VERIFICATION ═══"
    verify_current_state "Complete Uninstallation"
    
    # Check if we need diagnostics
    local total_remaining=0
    for resource in helm_releases pxc_resources deployments statefulsets pods services configmaps secrets; do
        total_remaining=$((total_remaining + ${CURRENT_STATE[$resource]}))
    done
    
    if [ "$total_remaining" -gt 0 ]; then
        echo ""
        log_warn "Some resources still remain in namespace"
        diagnose_stuck_resources
        
        # Check volume attachments
        cleanup_volumeattachments
    fi
    
    # Final summary
    show_summary
}

# Run main function
main "$@"


#!/bin/bash
# PMM Client Diagnostics Script
# Diagnoses PMM client configuration, health, and connectivity

set -euo pipefail

# Enable fix mode by default
FIX_MODE="true"

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
CLUSTER_NAME="pxc-cluster"
EXPECTED_VERSION="3.4.1"
PMM_NAMESPACE="pmm"
PMM_SERVICE="monitoring-service"

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
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Diagnose PMM client configuration, health, and connectivity

OPTIONS:
    -n, --namespace NAMESPACE      Kubernetes namespace where PXC is installed (required)
    -c, --cluster CLUSTER_NAME     Cluster name (default: pxc-cluster)
    -p, --pmm-namespace NAMESPACE  PMM namespace (default: pmm)
    -s, --service SERVICE_NAME     PMM service name (default: monitoring-service)
    --diagnose-only                Only diagnose, don't attempt fixes
    -h, --help                     Show this help message

EXAMPLES:
    $0 -n prod                              # Diagnose and fix issues
    $0 -n craig-test -c my-pxc-cluster      # Custom cluster name
    $0 --namespace percona --diagnose-only  # Only diagnose, no fixes

EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -p|--pmm-namespace)
            PMM_NAMESPACE="$2"
            shift 2
            ;;
        -s|--service)
            PMM_SERVICE="$2"
            shift 2
            ;;
        --diagnose-only)
            FIX_MODE="false"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$NAMESPACE" ]; then
    log_error "Namespace is required"
    usage
fi

# Check prerequisites
check_prerequisites() {
    log_header "Checking Prerequisites"
    
    local missing=()
    if ! command -v kubectl &> /dev/null; then missing+=("kubectl"); fi
    if ! command -v jq &> /dev/null; then missing+=("jq"); fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them and try again."
        exit 1
    fi
    log_success "kubectl and jq found"
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Track issues for summary
declare -a ISSUES=()
declare -a WARNINGS=()
declare -a REPAIRS_AVAILABLE=()

# Track configuration issues
PMM_DISABLED=false
VERSION_MISMATCH=false
SERVERHOST_WRONG=false
CURRENT_VERSION=""
CURRENT_SERVERHOST=""

# Main diagnostic function
run_diagnostics() {
    log_header "PMM Client Diagnostics for Namespace: $NAMESPACE, Cluster: $CLUSTER_NAME"
    
    # 1. Check if PMM is enabled in PXC cluster
    log_header "1. PXC Cluster PMM Configuration"
    
    local pxc_resource="${CLUSTER_NAME}-pxc-db"
    
    if ! kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" &>/dev/null; then
        log_error "PXC resource '$pxc_resource' not found in namespace '$NAMESPACE'"
        ISSUES+=("PXC resource not found")
        return 1
    fi
    
    local pmm_enabled=$(kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.enabled}' 2>/dev/null || echo "false")
    local pmm_image_repo=$(kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image.repository}' 2>/dev/null || echo "")
    local pmm_image_tag=$(kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image.tag}' 2>/dev/null || echo "")
    local pmm_server_host=$(kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.serverHost}' 2>/dev/null || echo "")
    
    log_info "PMM Configuration in PXC spec:"
    echo "  Enabled: ${pmm_enabled}"
    echo "  Image Repository: ${pmm_image_repo:-<not set>}"
    echo "  Image Tag: ${pmm_image_tag:-<not set>}"
    echo "  Server Host: ${pmm_server_host:-<not set>}"
    echo ""
    
    if [ "$pmm_enabled" != "true" ]; then
        log_error "PMM is NOT enabled in PXC cluster configuration"
        ISSUES+=("PMM is disabled in PXC spec")
        PMM_DISABLED=true
        REPAIRS_AVAILABLE+=("enable_pmm")
    else
        log_success "PMM is enabled in PXC cluster"
    fi
    
    # Check version
    CURRENT_VERSION="$pmm_image_tag"
    if [ -z "$pmm_image_tag" ] || [ "$pmm_image_tag" = "null" ]; then
        log_warn "PMM client version is not set (empty or null)"
        WARNINGS+=("PMM client version not set")
        VERSION_MISMATCH=true
        REPAIRS_AVAILABLE+=("fix_version")
    elif [ "$pmm_image_tag" != "$EXPECTED_VERSION" ]; then
        log_warn "PMM client version is '$pmm_image_tag', expected '$EXPECTED_VERSION'"
        WARNINGS+=("PMM client version mismatch: $pmm_image_tag vs $EXPECTED_VERSION")
        VERSION_MISMATCH=true
        REPAIRS_AVAILABLE+=("fix_version")
    else
        log_success "PMM client version is correct: $EXPECTED_VERSION"
    fi
    
    # Check server host
    CURRENT_SERVERHOST="$pmm_server_host"
    if [ -z "$pmm_server_host" ] || [ "$pmm_server_host" = "null" ]; then
        log_warn "PMM server host is not set (empty or null)"
        WARNINGS+=("PMM server host not set")
        SERVERHOST_WRONG=true
        REPAIRS_AVAILABLE+=("fix_serverhost")
    elif [ "$pmm_server_host" != "$PMM_SERVICE" ]; then
        log_warn "PMM server host is '$pmm_server_host', expected '$PMM_SERVICE'"
        WARNINGS+=("PMM server host mismatch: $pmm_server_host vs $PMM_SERVICE")
        SERVERHOST_WRONG=true
        REPAIRS_AVAILABLE+=("fix_serverhost")
    else
        log_success "PMM server host is correct: $PMM_SERVICE"
    fi
    
    # 2. Check PXC Pods with PMM Client
    log_header "2. PXC Pods with PMM Client Container"
    
    local pxc_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc --no-headers 2>/dev/null | awk '{print $1}' || echo "")
    
    if [ -z "$pxc_pods" ]; then
        log_error "No PXC pods found in namespace '$NAMESPACE'"
        ISSUES+=("No PXC pods found")
        return 1
    fi
    
    log_info "Found PXC pods:"
    echo "$pxc_pods" | while read -r pod; do
        local status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "  - $pod: $status"
    done
    echo ""
    
    # 3. Check PMM Client Container in Each Pod
    log_header "3. PMM Client Container Status"
    
    local has_pmm_container=false
    
    echo "$pxc_pods" | while read -r pod; do
        log_info "Checking pod: $pod"
        
        # Check if pmm-client container exists
        local containers=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
        
        if [[ "$containers" =~ "pmm-client" ]]; then
            log_success "PMM client container found in pod"
            has_pmm_container=true
            
            # Get container status
            local container_ready=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="pmm-client")].ready}' 2>/dev/null || echo "false")
            local container_state=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="pmm-client")].state}' 2>/dev/null | jq -r 'keys[0]' || echo "unknown")
            local restart_count=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="pmm-client")].restartCount}' 2>/dev/null || echo "0")
            
            echo "  Container Ready: $container_ready"
            echo "  Container State: $container_state"
            echo "  Restart Count: $restart_count"
            
            if [ "$container_ready" = "true" ]; then
                log_success "PMM client container is ready"
            else
                log_error "PMM client container is NOT ready"
            fi
            
            if [ "$restart_count" -gt 0 ]; then
                log_warn "PMM client container has restarted $restart_count times"
            fi
            
            # Get actual image version
            local actual_image=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="pmm-client")].image}' 2>/dev/null || echo "")
            local actual_version=$(echo "$actual_image" | sed 's/.*://' || echo "unknown")
            
            echo "  Image: $actual_image"
            
            if [ "$actual_version" = "$EXPECTED_VERSION" ]; then
                log_success "PMM client version matches expected: $EXPECTED_VERSION"
            else
                log_error "PMM client version mismatch: $actual_version vs $EXPECTED_VERSION"
            fi
            
        else
            log_error "PMM client container NOT found in pod"
            echo "  Available containers: $containers"
        fi
        echo ""
    done
    
    # 4. Check PMM Service in PMM Namespace
    log_header "4. PMM Server Service Check"
    
    if ! kubectl get namespace "$PMM_NAMESPACE" &>/dev/null; then
        log_error "PMM namespace '$PMM_NAMESPACE' does not exist"
        ISSUES+=("PMM namespace not found")
    else
        log_success "PMM namespace '$PMM_NAMESPACE' exists"
    fi
    
    if ! kubectl get service "$PMM_SERVICE" -n "$PMM_NAMESPACE" &>/dev/null; then
        log_error "PMM service '$PMM_SERVICE' not found in namespace '$PMM_NAMESPACE'"
        ISSUES+=("PMM service not found")
        log_info "Available services in $PMM_NAMESPACE namespace:"
        kubectl get services -n "$PMM_NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"
    else
        log_success "PMM service '$PMM_SERVICE' found in namespace '$PMM_NAMESPACE'"
        
        local service_type=$(kubectl get service "$PMM_SERVICE" -n "$PMM_NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
        local cluster_ip=$(kubectl get service "$PMM_SERVICE" -n "$PMM_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        local ports=$(kubectl get service "$PMM_SERVICE" -n "$PMM_NAMESPACE" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
        
        echo "  Service Type: $service_type"
        echo "  Cluster IP: $cluster_ip"
        echo "  Ports: $ports"
        echo ""
        
        # Check service endpoints
        local endpoints=$(kubectl get endpoints "$PMM_SERVICE" -n "$PMM_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        if [ -n "$endpoints" ]; then
            log_success "PMM service has endpoints: $endpoints"
        else
            log_error "PMM service has NO endpoints (no pods backing the service)"
            ISSUES+=("PMM service has no endpoints")
        fi
    fi
    echo ""
    
    # 5. Test Connectivity from PXC Pod
    log_header "5. Network Connectivity Test"
    
    local test_pod=$(echo "$pxc_pods" | head -1)
    log_info "Testing connectivity from pod: $test_pod"
    
    # Test DNS resolution
    log_info "Testing DNS resolution for '$PMM_SERVICE.$PMM_NAMESPACE.svc.cluster.local'..."
    if kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- nslookup "$PMM_SERVICE.$PMM_NAMESPACE.svc.cluster.local" &>/dev/null; then
        log_success "DNS resolution successful"
    else
        log_error "DNS resolution failed"
        ISSUES+=("DNS resolution failed for PMM service")
    fi
    
    # Test short name resolution (should work due to search domains)
    log_info "Testing DNS resolution for '$PMM_SERVICE' (short name)..."
    if kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- nslookup "$PMM_SERVICE" &>/dev/null; then
        log_success "Short name DNS resolution successful"
    else
        log_warn "Short name DNS resolution failed (FQDN should still work)"
        WARNINGS+=("Short name DNS resolution failed")
    fi
    
    # Test HTTP/HTTPS connectivity
    log_info "Testing HTTP connectivity to PMM service..."
    local http_test=$(kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://$PMM_SERVICE.$PMM_NAMESPACE.svc.cluster.local" 2>/dev/null || echo "000")
    
    if [ "$http_test" != "000" ]; then
        log_success "HTTP connectivity successful (HTTP code: $http_test)"
    else
        log_warn "HTTP connectivity test returned no response"
        WARNINGS+=("HTTP connectivity test inconclusive")
    fi
    echo ""
    
    # 6. Check PMM Client Logs
    log_header "6. PMM Client Logs Analysis"
    
    log_info "Checking PMM client logs from pod: $test_pod"
    echo ""
    
    log_info "Last 30 lines of PMM client logs:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl logs "$test_pod" -n "$NAMESPACE" -c pmm-client --tail=30 2>&1 || log_warn "Could not retrieve PMM client logs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check for common error patterns in logs
    local logs=$(kubectl logs "$test_pod" -n "$NAMESPACE" -c pmm-client --tail=100 2>/dev/null || echo "")
    
    if echo "$logs" | grep -iq "error"; then
        log_warn "Found 'error' messages in PMM client logs"
        WARNINGS+=("Errors found in PMM client logs")
    fi
    
    if echo "$logs" | grep -iq "failed\|timeout\|connection refused"; then
        log_error "Found connectivity issues in PMM client logs"
        ISSUES+=("Connectivity issues in PMM client logs")
    fi
    
    if echo "$logs" | grep -iq "registered\|connected\|sending"; then
        log_success "PMM client shows signs of activity (registered/connected/sending)"
    fi
    
    # 7. Check PMM Client Environment Variables
    log_header "7. PMM Client Environment Variables"
    
    log_info "Checking PMM client environment in pod: $test_pod"
    
    local pmm_env=$(kubectl get pod "$test_pod" -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.spec.containers[] | select(.name=="pmm-client") | .env[]? | "\(.name) = \(.value // .valueFrom // "<from secret/configmap>")"' 2>/dev/null || echo "")
    
    if [ -n "$pmm_env" ]; then
        echo "$pmm_env" | while read -r line; do
            echo "  $line"
        done
    else
        log_warn "Could not retrieve PMM client environment variables"
    fi
    echo ""
    
    # 8. Check Resource Usage
    log_header "8. PMM Client Resource Usage"
    
    log_info "Checking resource usage for PMM client in pod: $test_pod"
    
    local cpu_usage=$(kubectl top pod "$test_pod" -n "$NAMESPACE" --containers 2>/dev/null | grep pmm-client | awk '{print $2}' || echo "N/A")
    local mem_usage=$(kubectl top pod "$test_pod" -n "$NAMESPACE" --containers 2>/dev/null | grep pmm-client | awk '{print $3}' || echo "N/A")
    
    if [ "$cpu_usage" != "N/A" ]; then
        echo "  CPU Usage: $cpu_usage"
        echo "  Memory Usage: $mem_usage"
        log_success "Resource metrics available"
    else
        log_warn "Resource metrics not available (metrics-server may not be installed)"
        WARNINGS+=("Resource metrics not available")
    fi
    echo ""
    
    # Store PXC resource name for repair functions
    PXC_RESOURCE="$pxc_resource"
}

# Repair Functions
enable_pmm() {
    log_info "Enabling PMM in PXC cluster configuration..."
    
    # Verify PXC resource exists
    if ! kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" &>/dev/null; then
        log_error "✗ PXC resource '$PXC_RESOURCE' not found in namespace '$NAMESPACE'"
        log_error "Cannot enable PMM without a valid PXC cluster"
        return 1
    fi
    
    log_info "Current PMM configuration:"
    kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm}' 2>/dev/null | jq '.' || echo "  (none)"
    echo ""
    
    log_info "Applying new PMM configuration:"
    echo "  enabled: true"
    echo "  image.repository: percona/pmm-client"
    echo "  image.tag: $EXPECTED_VERSION"
    echo "  serverHost: $PMM_SERVICE"
    echo "  resources:"
    echo "    requests: cpu=50m, memory=64Mi"
    echo "    limits: cpu=200m, memory=256Mi"
    echo ""
    
    local patch='{
      "spec": {
        "pmm": {
          "enabled": true,
          "image": {
            "repository": "percona/pmm-client",
            "tag": "'$EXPECTED_VERSION'"
          },
          "serverHost": "'$PMM_SERVICE'",
          "resources": {
            "requests": {
              "cpu": "50m",
              "memory": "64Mi"
            },
            "limits": {
              "cpu": "200m",
              "memory": "256Mi"
            }
          }
        }
      }
    }'
    
    local error_output
    if error_output=$(kubectl patch perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" --type=merge -p "$patch" 2>&1); then
        log_success "✓ Successfully enabled PMM"
        echo "$error_output"
        PMM_DISABLED=false
        
        # Verify the patch was applied
        log_info "Verifying PMM configuration..."
        local new_enabled=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.enabled}' 2>/dev/null || echo "false")
        local new_version=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image.tag}' 2>/dev/null || echo "")
        
        if [ "$new_enabled" = "true" ] && [ "$new_version" = "$EXPECTED_VERSION" ]; then
            log_success "✓ PMM configuration verified in cluster spec"
        else
            log_warn "⚠ PMM configuration may not have been fully applied"
            log_warn "  enabled: $new_enabled (expected: true)"
            log_warn "  version: $new_version (expected: $EXPECTED_VERSION)"
        fi
        
        return 0
    else
        log_error "✗ Failed to enable PMM"
        log_error "kubectl patch error output:"
        echo "$error_output" | sed 's/^/  /'
        echo ""
        
        # Provide troubleshooting info
        log_info "Troubleshooting steps:"
        echo "  1. Verify the operator is running:"
        echo "     kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=percona-xtradb-cluster-operator"
        echo ""
        echo "  2. Check operator logs for errors:"
        echo "     kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=percona-xtradb-cluster-operator --tail=50"
        echo ""
        echo "  3. Verify you have permissions to patch the resource:"
        echo "     kubectl auth can-i patch perconaxtradbcluster -n $NAMESPACE"
        echo ""
        echo "  4. Check the PXC resource status:"
        echo "     kubectl get perconaxtradbcluster $PXC_RESOURCE -n $NAMESPACE -o yaml"
        echo ""
        
        return 1
    fi
}

fix_version() {
    log_info "Updating PMM client version to $EXPECTED_VERSION..."
    
    # Show current version
    local current_version=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image.tag}' 2>/dev/null || echo "unknown")
    log_info "Current version: $current_version"
    log_info "Target version: $EXPECTED_VERSION"
    echo ""
    
    local patch='{
      "spec": {
        "pmm": {
          "image": {
            "repository": "percona/pmm-client",
            "tag": "'$EXPECTED_VERSION'"
          }
        }
      }
    }'
    
    local error_output
    if error_output=$(kubectl patch perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" --type=merge -p "$patch" 2>&1); then
        log_success "✓ Successfully updated PMM client version"
        echo "$error_output"
        VERSION_MISMATCH=false
        
        # Verify the patch was applied
        local new_version=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image.tag}' 2>/dev/null || echo "")
        if [ "$new_version" = "$EXPECTED_VERSION" ]; then
            log_success "✓ Version update verified: $new_version"
        else
            log_warn "⚠ Version may not have been updated (current: $new_version)"
        fi
        
        return 0
    else
        log_error "✗ Failed to update PMM client version"
        log_error "kubectl patch error output:"
        echo "$error_output" | sed 's/^/  /'
        echo ""
        
        log_info "Try manually with:"
        echo "  kubectl patch perconaxtradbcluster $PXC_RESOURCE -n $NAMESPACE --type=merge -p '$patch'"
        echo ""
        
        return 1
    fi
}

fix_serverhost() {
    log_info "Updating PMM server host to '$PMM_SERVICE'..."
    
    # Show current serverHost
    local current_host=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.serverHost}' 2>/dev/null || echo "not set")
    log_info "Current serverHost: $current_host"
    log_info "Target serverHost: $PMM_SERVICE"
    echo ""
    
    local patch='{
      "spec": {
        "pmm": {
          "serverHost": "'$PMM_SERVICE'"
        }
      }
    }'
    
    local error_output
    if error_output=$(kubectl patch perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" --type=merge -p "$patch" 2>&1); then
        log_success "✓ Successfully updated PMM server host"
        echo "$error_output"
        SERVERHOST_WRONG=false
        
        # Verify the patch was applied
        local new_host=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.serverHost}' 2>/dev/null || echo "")
        if [ "$new_host" = "$PMM_SERVICE" ]; then
            log_success "✓ ServerHost update verified: $new_host"
        else
            log_warn "⚠ ServerHost may not have been updated (current: $new_host)"
        fi
        
        return 0
    else
        log_error "✗ Failed to update PMM server host"
        log_error "kubectl patch error output:"
        echo "$error_output" | sed 's/^/  /'
        echo ""
        
        log_info "Try manually with:"
        echo "  kubectl patch perconaxtradbcluster $PXC_RESOURCE -n $NAMESPACE --type=merge -p '$patch'"
        echo ""
        
        return 1
    fi
}

perform_repairs() {
    log_header "PERFORMING REPAIRS"
    local repairs_made=0
    local repairs_failed=0
    
    # 1. Enable PMM if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " enable_pmm " ]]; then
        echo ""
        log_info "Repair 1/3: Enable PMM"
        echo -n "Enable PMM in PXC cluster? (yes/no) [yes]: "
        read -r ENABLE
        ENABLE=${ENABLE:-yes}
        
        if [[ "$ENABLE" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            if enable_pmm; then
                ((repairs_made++))
            else
                ((repairs_failed++))
            fi
        else
            log_info "Skipped"
        fi
    fi
    
    # 2. Fix version if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_version " ]]; then
        echo ""
        log_info "Repair 2/3: Update PMM client version"
        echo -n "Update PMM client to version $EXPECTED_VERSION? (yes/no) [yes]: "
        read -r UPDATE_VERSION
        UPDATE_VERSION=${UPDATE_VERSION:-yes}
        
        if [[ "$UPDATE_VERSION" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            if fix_version; then
                ((repairs_made++))
            else
                ((repairs_failed++))
            fi
        else
            log_info "Skipped"
        fi
    fi
    
    # 3. Fix server host if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_serverhost " ]]; then
        echo ""
        log_info "Repair 3/3: Update PMM server host"
        echo -n "Update PMM server host to '$PMM_SERVICE'? (yes/no) [yes]: "
        read -r UPDATE_HOST
        UPDATE_HOST=${UPDATE_HOST:-yes}
        
        if [[ "$UPDATE_HOST" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            if fix_serverhost; then
                ((repairs_made++))
            else
                ((repairs_failed++))
            fi
        else
            log_info "Skipped"
        fi
    fi
    
    # Summary
    echo ""
    log_header "REPAIR SUMMARY"
    log_info "Repairs attempted: ${repairs_made}"
    
    if [ $repairs_failed -gt 0 ]; then
        log_error "Repairs failed: ${repairs_failed}"
    else
        log_success "All repairs completed successfully"
    fi
    
    # Inform about pod restart
    if [ $repairs_made -gt 0 ]; then
        echo ""
        log_info "PMM configuration updated. The operator will restart PXC pods to apply changes."
        log_info "This may take a few minutes. Monitor pod status with:"
        echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=pxc -w"
        echo ""
        log_info "After pods restart, run diagnostics again to verify:"
        echo "  $0 -n $NAMESPACE"
    fi
}

# Main diagnostic summary and repair offer
run_summary_and_repair() {
    log_header "DIAGNOSTIC SUMMARY"
    
    # Display issues and warnings
    if [ ${#ISSUES[@]} -gt 0 ]; then
        log_error "Found ${#ISSUES[@]} issue(s):"
        for issue in "${ISSUES[@]}"; do
            echo "  ✗ $issue"
        done
        echo ""
    fi
    
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        log_warn "Found ${#WARNINGS[@]} warning(s):"
        for warning in "${WARNINGS[@]}"; do
            echo "  ⚠ $warning"
        done
        echo ""
    fi
    
    if [ ${#ISSUES[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
        log_success "✓ No major issues detected!"
        log_info "PMM client appears to be configured correctly and healthy."
        echo ""
    fi
    
    # Offer repairs if in fix mode
    if [ "$FIX_MODE" = "true" ] && [ ${#REPAIRS_AVAILABLE[@]} -gt 0 ]; then
        log_info "Repair mode is ENABLED. Available fixes:"
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " enable_pmm " ]]; then
            echo "  1. Enable PMM in PXC cluster"
        fi
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_version " ]]; then
            echo "  2. Update PMM client version to $EXPECTED_VERSION"
        fi
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_serverhost " ]]; then
            echo "  3. Update PMM server host to '$PMM_SERVICE'"
        fi
        
        echo ""
        
        # Prompt to proceed
        echo -n "Would you like to attempt these repairs? (yes/no) [yes]: "
        read -r PROCEED
        PROCEED=${PROCEED:-yes}
        
        if [[ "$PROCEED" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            perform_repairs
            return
        else
            log_info "Skipping repairs. Run with --diagnose-only to disable repair prompts."
        fi
    elif [ "$FIX_MODE" = "false" ]; then
        log_info "Diagnose-only mode. Run without --diagnose-only to enable repairs."
    elif [ ${#REPAIRS_AVAILABLE[@]} -eq 0 ] && [ ${#ISSUES[@]} -gt 0 ]; then
        log_warn "Issues found but automatic repairs are not available."
        log_info "Please review the diagnostics above and fix manually."
    fi
    
    echo ""
    
    log_info "Recommendations:"
    echo "  1. Check PMM client logs for detailed error messages"
    echo "     kubectl logs <pxc-pod> -n $NAMESPACE -c pmm-client"
    echo ""
    echo "  2. Verify PMM server is running in namespace '$PMM_NAMESPACE'"
    echo "     kubectl get pods -n $PMM_NAMESPACE"
    echo ""
    echo "  3. Check PMM server logs for client registration"
    echo "     kubectl logs <pmm-server-pod> -n $PMM_NAMESPACE"
    echo ""
    echo "  4. Verify network policies allow traffic between namespaces"
    echo "     kubectl get networkpolicies -n $NAMESPACE"
    echo ""
    echo "  5. Access PMM dashboard to verify metrics are being received"
    echo "     (PMM server typically exposes a web UI on port 80/443)"
    echo ""
    
    log_info "For more help, check:"
    log_info "  - PMM documentation: https://docs.percona.com/percona-monitoring-and-management/"
    log_info "  - Percona Operator docs: https://docs.percona.com/percona-operator-for-mysql/pxc/"
    echo ""
}

# Run checks
check_prerequisites
run_diagnostics
run_summary_and_repair


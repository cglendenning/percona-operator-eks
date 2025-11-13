#!/bin/bash
# PMM Client Diagnostics Script (PMM v3 Compatible)
# Diagnoses PMM client configuration, health, and connectivity
# Supports PMM v3 authentication via 'pmmservertoken' secret key (users.PMMServerToken)
# Ref: https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/users/users.go#L23

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
PMM_SERVICE="monitoring-service.pmm.svc.cluster.local"

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
    -s, --service SERVICE_NAME     PMM service FQDN (default: monitoring-service.pmm.svc.cluster.local)
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
    local pmm_image=$(kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image}' 2>/dev/null || echo "")
    local pmm_server_host=$(kubectl get perconaxtradbcluster "$pxc_resource" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.serverHost}' 2>/dev/null || echo "")
    
    # Extract version from image string (format: repository:tag)
    local pmm_image_tag=""
    if [ -n "$pmm_image" ]; then
        pmm_image_tag=$(echo "$pmm_image" | sed 's/.*://')
    fi
    
    log_info "PMM Configuration in PXC spec:"
    echo "  Enabled: ${pmm_enabled}"
    echo "  Image: ${pmm_image:-<not set>}"
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
    
    # Check for PMM authentication secret
    log_header "1.1. PMM Authentication Secret"
    
    local secret_name="${CLUSTER_NAME}-pxc-db-secrets"
    local internal_secret_name="internal-${CLUSTER_NAME}-pxc-db"
    log_info "Checking for PMM authentication in secret: $secret_name"
    
    if ! kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
        log_error "Cluster secrets not found: $secret_name"
        ISSUES+=("Cluster secrets not found")
    else
        log_success "Cluster secrets found: $secret_name"
        
        # Check for pmmservertoken (PMM v3 token) - primary method for PMM v3
        local pmmservertoken=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.data.pmmservertoken}' 2>/dev/null || echo "")
        
        # Also check for pmmserverkey (PMM v2 compatibility)
        local pmmserverkey=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.data.pmmserverkey}' 2>/dev/null || echo "")
        
        local has_auth=false
        
        if [ -n "$pmmservertoken" ] && [ "$pmmservertoken" != "null" ]; then
            log_success "PMM v3 authentication token (pmmservertoken) exists in secrets ✓"
            local decoded_length=$(echo "$pmmservertoken" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
            echo "  Token length: $decoded_length characters"
            echo "  This is the REQUIRED key for PMM v3 (users.PMMServerToken)"
            has_auth=true
        elif [ -n "$pmmserverkey" ] && [ "$pmmserverkey" != "null" ]; then
            log_warn "PMM v2 authentication key (pmmserverkey) exists but 'pmmservertoken' is missing"
            local decoded_length=$(echo "$pmmserverkey" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
            echo "  Token length: $decoded_length characters"
            log_error "For PMM v3, the operator requires the 'pmmservertoken' key (users.PMMServerToken)"
            ISSUES+=("PMM v3 requires 'pmmservertoken' key in secret")
            REPAIRS_AVAILABLE+=("fix_pmm_secret")
        else
            log_error "PMM authentication token (pmmservertoken) is MISSING from secrets"
            ISSUES+=("PMM authentication secret missing")
            REPAIRS_AVAILABLE+=("fix_pmm_secret")
            echo ""
            log_info "PMM v3 requires authentication credentials in the cluster secret."
            echo "  The secret '$secret_name' MUST contain a 'pmmservertoken' key with the PMM API token."
            echo ""
            log_info "Operator code reference:"
            echo "  The operator checks: secret.Data[users.PMMServerToken]"
            echo "  Where users.PMMServerToken = 'pmmservertoken'"
            echo "  See: https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/users/users.go#L23"
            echo ""
            log_info "To add the PMM server API key:"
            echo "  1. Get your PMM v3 server API key from the PMM web UI:"
            echo "     • Log into PMM"
            echo "     • Navigate to Configuration → API Keys"
            echo "     • Generate a new API key (or use existing)"
            echo ""
            echo "  2. Add it to the secret with the correct key name 'pmmservertoken':"
            echo "     PMM_API_KEY='your-api-key-here'"
            echo "     kubectl patch secret $secret_name -n $NAMESPACE --type=merge -p \"{\\\"data\\\":{\\\"pmmservertoken\\\":\\\"\$(echo -n \\\$PMM_API_KEY | base64)\\\"}}\""
            echo ""
            echo "  3. Or manually edit the secret:"
            echo "     kubectl edit secret $secret_name -n $NAMESPACE"
            echo "     # Add: pmmservertoken: <base64-encoded-api-key>"
            echo ""
        fi
        
        # Check for internal secrets sync issue
        if [ "$has_auth" = true ]; then
            log_info "Checking internal secrets synchronization..."
            
            if ! kubectl get secret "$internal_secret_name" -n "$NAMESPACE" &>/dev/null; then
                log_warn "Internal secret not found: $internal_secret_name"
                log_info "This is normal if the cluster was just created. The operator will create it."
            else
                log_success "Internal secret exists: $internal_secret_name"
                
                # Check if internal secret has PMM keys
                local internal_pmmserverkey=$(kubectl get secret "$internal_secret_name" -n "$NAMESPACE" -o jsonpath='{.data.pmmserverkey}' 2>/dev/null || echo "")
                
                if [ -z "$internal_pmmserverkey" ] || [ "$internal_pmmserverkey" != "$pmmserverkey" ]; then
                    log_error "Internal secrets are OUT OF SYNC with cluster secrets!"
                    ISSUES+=("Secrets and internal secrets out of sync")
                    echo ""
                    log_info "The operator maintains an internal copy of secrets, and they're not synchronized."
                    echo "  This commonly happens when you update the PMM credentials after the cluster is created."
                    echo ""
                    log_info "To fix the sync issue:"
                    echo "  1. Delete the internal secret (operator will recreate it):"
                    echo "     kubectl delete secret $internal_secret_name -n $NAMESPACE"
                    echo ""
                    echo "  2. Wait for operator to recreate it (usually a few seconds)"
                    echo ""
                    echo "  3. Restart PXC pods to apply the new credentials:"
                    echo "     kubectl delete pod -l app.kubernetes.io/component=pxc -n $NAMESPACE"
                    echo ""
                else
                    log_success "Internal secrets are synchronized with cluster secrets"
                fi
            fi
        fi
    fi
    echo ""
    
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
        log_info "Available namespaces:"
        kubectl get namespaces --no-headers 2>/dev/null | awk '{print "  - " $1}' | head -20 || echo "  (none)"
    else
        log_success "PMM namespace '$PMM_NAMESPACE' exists"
    fi
    
    # Extract short service name from FQDN
    local service_name=$(echo "$PMM_SERVICE" | cut -d'.' -f1)
    
    if ! kubectl get service "$service_name" -n "$PMM_NAMESPACE" &>/dev/null; then
        log_error "PMM service '$service_name' not found in namespace '$PMM_NAMESPACE'"
        ISSUES+=("PMM service not found")
        log_info "Available services in $PMM_NAMESPACE namespace:"
        kubectl get services -n "$PMM_NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"
    else
        log_success "PMM service '$service_name' found in namespace '$PMM_NAMESPACE'"
        
        local service_type=$(kubectl get service "$service_name" -n "$PMM_NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
        local cluster_ip=$(kubectl get service "$service_name" -n "$PMM_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        local ports=$(kubectl get service "$service_name" -n "$PMM_NAMESPACE" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
        
        echo "  Service Type: $service_type"
        echo "  Cluster IP: $cluster_ip"
        echo "  Ports: $ports"
        echo ""
        
        # Check service endpoints
        local endpoints=$(kubectl get endpoints "$service_name" -n "$PMM_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        if [ -n "$endpoints" ]; then
            log_success "PMM service has endpoints: $endpoints"
        else
            log_error "PMM service has NO endpoints (no pods backing the service)"
            ISSUES+=("PMM service has no endpoints")
            
            # Check for PMM server pods
            log_info "Checking for PMM server pods..."
            local pmm_pods=$(kubectl get pods -n "$PMM_NAMESPACE" --no-headers 2>/dev/null | grep -v "^$" || echo "")
            if [ -z "$pmm_pods" ]; then
                log_error "No pods found in PMM namespace"
                ISSUES+=("No PMM server pods running")
            else
                log_info "Found pods in PMM namespace:"
                echo "$pmm_pods" | while read -r line; do
                    echo "  - $line"
                done
            fi
        fi
    fi
    echo ""
    
    # 5. Test Connectivity from PXC Pod
    log_header "5. Network Connectivity Test"
    
    local test_pod=$(echo "$pxc_pods" | head -1)
    log_info "Testing connectivity from pod: $test_pod"
    echo ""
    
    # Test DNS resolution for FQDN
    log_info "Testing DNS resolution for '$PMM_SERVICE'..."
    local dns_output=$(kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- getent hosts "$PMM_SERVICE" 2>&1 || echo "")
    if [ -n "$dns_output" ] && echo "$dns_output" | grep -qv "not found\|error"; then
        local resolved_ip=$(echo "$dns_output" | awk '{print $1}')
        log_success "DNS resolution successful → $resolved_ip"
    else
        log_error "DNS resolution failed for '$PMM_SERVICE'"
        ISSUES+=("DNS resolution failed for PMM service FQDN")
        echo "  DNS output:"
        if [ -z "$dns_output" ]; then
            echo "    (no output - host not found)"
        else
            echo "$dns_output" | sed 's/^/    /'
        fi
    fi
    echo ""
    
    # Test TCP connectivity (port 443) using bash built-in
    log_info "Testing TCP connectivity to PMM service on port 443..."
    local tcp_test=$(kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$PMM_SERVICE/443' 2>&1 && echo 'success' || echo 'failed'")
    if echo "$tcp_test" | grep -q "success"; then
        log_success "TCP port 443 is reachable"
    else
        log_error "TCP port 443 is NOT reachable"
        ISSUES+=("Cannot connect to PMM service on port 443")
        echo "  TCP test output:"
        echo "$tcp_test" | sed 's/^/    /'
    fi
    echo ""
    
    # Test HTTP connectivity
    log_info "Testing HTTP connectivity to PMM service..."
    local http_output=$(kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- timeout 5 curl -s -o /dev/null -w "HTTP_CODE:%{http_code}" "http://$PMM_SERVICE" 2>&1)
    local http_test=$(echo "$http_output" | grep "HTTP_CODE:" | cut -d: -f2 || echo "000")
    
    if [ "$http_test" != "000" ] && [ "$http_test" != "" ]; then
        log_success "HTTP connectivity successful (HTTP code: $http_test)"
    else
        log_warn "HTTP connectivity test returned no response (HTTP code: ${http_test:-000})"
        WARNINGS+=("HTTP connectivity test inconclusive")
        if echo "$http_output" | grep -qv "HTTP_CODE:"; then
            echo "  Error output:"
            echo "$http_output" | grep -v "HTTP_CODE:" | sed 's/^/    /'
        fi
    fi
    echo ""
    
    # Test HTTPS connectivity
    log_info "Testing HTTPS connectivity to PMM service..."
    local https_output=$(kubectl exec "$test_pod" -n "$NAMESPACE" -c pxc -- timeout 5 curl -ks -o /dev/null -w "HTTP_CODE:%{http_code}" "https://$PMM_SERVICE" 2>&1)
    local https_test=$(echo "$https_output" | grep "HTTP_CODE:" | cut -d: -f2 || echo "000")
    
    if [ "$https_test" != "000" ] && [ "$https_test" != "" ]; then
        log_success "HTTPS connectivity successful (HTTP code: $https_test)"
    else
        log_error "HTTPS connectivity test failed (HTTP code: ${https_test:-000})"
        ISSUES+=("Cannot reach PMM service via HTTPS")
        if echo "$https_output" | grep -qv "HTTP_CODE:"; then
            echo "  Error output:"
            echo "$https_output" | grep -v "HTTP_CODE:" | sed 's/^/    /'
        fi
    fi
    echo ""
    
    # 6. Check PMM Client Logs
    log_header "6. PMM Client Logs Analysis"
    
    log_info "Checking PMM client logs from pod: $test_pod"
    echo ""
    
    # Get last 100 lines for analysis
    local logs=$(kubectl logs "$test_pod" -n "$NAMESPACE" -c pmm-client --tail=100 2>/dev/null || echo "")
    
    if [ -z "$logs" ]; then
        log_warn "Could not retrieve PMM client logs (container may not be running)"
        WARNINGS+=("PMM client logs unavailable")
    else
        # Analyze logs for specific issues
        local has_connection_success=false
        local has_errors=false
        local has_dns_error=false
        local has_auth_error=false
        local has_timeout_error=false
        
        if echo "$logs" | grep -iq "connected to pmm\|registered with pmm\|successfully registered"; then
            log_success "PMM client successfully connected to PMM server"
            has_connection_success=true
        fi
        
        if echo "$logs" | grep -iq "cannot resolve\|no such host\|dns"; then
            log_error "DNS resolution errors found in logs"
            ISSUES+=("DNS resolution errors in PMM client logs")
            has_dns_error=true
            has_errors=true
        fi
        
        if echo "$logs" | grep -iq "unauthorized\|authentication\|forbidden\|401\|403\|invalid.*key\|invalid.*token\|invalid.*credentials\|missing.*token\|missing.*credentials"; then
            log_error "Authentication/authorization errors found in logs"
            ISSUES+=("PMM authentication failed - check pmmserver secret")
            has_auth_error=true
            has_errors=true
        fi
        
        if echo "$logs" | grep -iq "timeout\|timed out\|deadline exceeded"; then
            log_error "Timeout errors found in logs"
            ISSUES+=("Timeout errors in PMM client logs")
            has_timeout_error=true
            has_errors=true
        fi
        
        if echo "$logs" | grep -iq "connection refused\|connect: connection refused"; then
            log_error "Connection refused errors found in logs"
            ISSUES+=("Connection refused in PMM client logs")
            has_errors=true
        fi
        
        if echo "$logs" | grep -iq "failed\|error" && [ "$has_errors" = false ]; then
            log_warn "Generic error messages found in PMM client logs"
            WARNINGS+=("Errors found in PMM client logs")
        fi
        
        if [ "$has_connection_success" = false ]; then
            log_warn "No successful connection messages found in recent logs"
            WARNINGS+=("PMM client has not logged successful connection recently")
        fi
        
        # Display recent log excerpt
        log_info "Last 30 lines of PMM client logs:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$logs" | tail -30
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Show specific error context if found
        if [ "$has_dns_error" = true ]; then
            log_info "DNS-related errors:"
            echo "$logs" | grep -i "cannot resolve\|no such host\|dns" | sed 's/^/  /'
            echo ""
        fi
        
        if [ "$has_auth_error" = true ]; then
            log_info "Authentication-related errors:"
            echo "$logs" | grep -i "unauthorized\|authentication\|forbidden\|401\|403" | sed 's/^/  /'
            echo ""
        fi
        
        if [ "$has_timeout_error" = true ]; then
            log_info "Timeout-related errors:"
            echo "$logs" | grep -i "timeout\|timed out\|deadline exceeded" | sed 's/^/  /'
            echo ""
        fi
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
    
    # 9. Check Percona Operator Status
    log_header "9. Percona Operator Status"
    
    log_info "Checking for Percona Operator in namespace: $NAMESPACE"
    
    local operator_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=percona-xtradb-cluster-operator --no-headers 2>/dev/null || echo "")
    
    if [ -z "$operator_pods" ]; then
        log_error "No Percona Operator pods found in namespace '$NAMESPACE'"
        ISSUES+=("Percona Operator not running")
    else
        log_success "Found Percona Operator pods:"
        echo "$operator_pods" | while read -r pod_line; do
            local pod_name=$(echo "$pod_line" | awk '{print $1}')
            local pod_ready=$(echo "$pod_line" | awk '{print $2}')
            local pod_status=$(echo "$pod_line" | awk '{print $3}')
            echo "  - $pod_name: $pod_status ($pod_ready ready)"
            
            # Check if operator is healthy
            if [ "$pod_status" != "Running" ]; then
                log_error "Operator pod $pod_name is not Running"
                ISSUES+=("Operator pod not running: $pod_name")
            fi
        done
        echo ""
        
        # Check operator logs for PMM-related errors
        local operator_pod=$(echo "$operator_pods" | head -1 | awk '{print $1}')
        log_info "Checking operator logs for PMM-related messages..."
        local operator_logs=$(kubectl logs "$operator_pod" -n "$NAMESPACE" --tail=100 2>/dev/null || echo "")
        
        local has_operator_pmm_errors=false
        
        # Check for secrets sync error (most common issue)
        if echo "$operator_logs" | grep -iq "can't enable PMM2\|pmmserverkey.*doesn't exist\|secrets and internal secrets are out of sync"; then
            log_error "Found PMM secrets synchronization error in operator logs"
            ISSUES+=("PMM secrets out of sync - operator cannot enable PMM")
            echo "  Operator error:"
            echo "$operator_logs" | grep -i "can't enable PMM2\|pmmserverkey\|secrets and internal secrets" | tail -3 | sed 's/^/    /'
            echo ""
            log_info "What this means:"
            echo "  • 'PMM2' = Percona Monitoring and Management version 2 (current version)"
            echo "  • The operator cannot find 'pmmserverkey' in your cluster secret"
            echo "  • OR the cluster secret and internal secret are out of sync"
            echo ""
            log_info "This error shows in Section 1.1 above with fix instructions."
            echo ""
            has_operator_pmm_errors=true
        fi
        
        # Check for authentication errors
        if echo "$operator_logs" | grep -iq "pmm.*auth\|pmm.*unauthorized\|pmm.*forbidden\|pmm.*invalid.*credential\|pmm.*missing.*token"; then
            log_error "Found PMM authentication errors in operator logs"
            ISSUES+=("PMM authentication errors in operator logs")
            echo "  Recent PMM authentication errors:"
            echo "$operator_logs" | grep -i "pmm.*auth\|pmm.*unauthorized\|pmm.*forbidden\|pmm.*invalid.*credential\|pmm.*missing.*token" | tail -5 | sed 's/^/    /'
            echo ""
            has_operator_pmm_errors=true
        fi
        
        # Check for general PMM errors
        if echo "$operator_logs" | grep -iq "pmm.*error\|pmm.*failed"; then
            log_warn "Found PMM-related errors in operator logs"
            WARNINGS+=("PMM errors in operator logs")
            echo "  Recent PMM-related errors:"
            echo "$operator_logs" | grep -i "pmm.*error\|pmm.*failed" | tail -5 | sed 's/^/    /'
            echo ""
            has_operator_pmm_errors=true
        fi
        
        if [ "$has_operator_pmm_errors" = false ]; then
            log_success "No PMM-related errors in recent operator logs"
        fi
    fi
    echo ""
    
    # 10. Check PMM Server Deployment Status
    log_header "10. PMM Server Deployment Status"
    
    log_info "Checking PMM server deployment in namespace: $PMM_NAMESPACE"
    
    local pmm_pods=$(kubectl get pods -n "$PMM_NAMESPACE" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pmm_pods" ]; then
        log_error "No PMM server pods found in namespace '$PMM_NAMESPACE'"
        ISSUES+=("No PMM server pods running")
    else
        log_success "Found PMM server pods:"
        echo "$pmm_pods" | while read -r pod_line; do
            local pod_name=$(echo "$pod_line" | awk '{print $1}')
            local pod_ready=$(echo "$pod_line" | awk '{print $2}')
            local pod_status=$(echo "$pod_line" | awk '{print $3}')
            echo "  - $pod_name: $pod_status ($pod_ready ready)"
            
            # Check if PMM server is healthy
            if [ "$pod_status" != "Running" ]; then
                log_error "PMM server pod $pod_name is not Running"
                ISSUES+=("PMM server pod not running: $pod_name")
            fi
        done
        echo ""
        
        # Check PMM server logs for client registration
        local pmm_server_pod=$(echo "$pmm_pods" | grep -i "pmm\|monitoring" | head -1 | awk '{print $1}')
        if [ -n "$pmm_server_pod" ]; then
            log_info "Checking PMM server logs for client registrations..."
            local pmm_server_logs=$(kubectl logs "$pmm_server_pod" -n "$PMM_NAMESPACE" --tail=100 2>/dev/null || echo "")
            
            if echo "$pmm_server_logs" | grep -iq "mysql.*registered\|client.*registered\|agent.*registered"; then
                log_success "PMM server shows client registration activity"
            else
                log_warn "No recent client registration messages in PMM server logs"
                WARNINGS+=("No recent client registrations in PMM server logs")
            fi
        fi
    fi
    echo ""
    
    # 11. Check Network Policies
    log_header "11. Network Policy Check"
    
    log_info "Checking for network policies that might block traffic..."
    
    local netpol_count=$(kubectl get networkpolicies -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$netpol_count" -gt 0 ]; then
        log_warn "Found $netpol_count network policy/policies in namespace '$NAMESPACE'"
        WARNINGS+=("Network policies present - may restrict traffic")
        kubectl get networkpolicies -n "$NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
            echo "  - $line"
        done
        echo ""
        log_info "Review network policies to ensure PMM client can reach PMM server"
    else
        log_success "No network policies found (traffic not restricted by NetworkPolicy)"
    fi
    echo ""
    
    # Store PXC resource name for repair functions
    PXC_RESOURCE="$pxc_resource"
}

# Repair Functions
enable_pmm() {
    log_info "Enabling PMM in PXC cluster configuration (spec.pmm section)..."
    log_info "This ONLY modifies PXC cluster in namespace '$NAMESPACE' - does NOT touch PMM namespace"
    echo ""
    
    # Verify PXC resource exists
    if ! kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" &>/dev/null; then
        log_error "✗ PXC resource '$PXC_RESOURCE' not found in namespace '$NAMESPACE'"
        log_error "Cannot enable PMM without a valid PXC cluster"
        return 1
    fi
    
    log_info "Current spec.pmm configuration in PXC cluster:"
    kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm}' 2>/dev/null | jq '.' || echo "  (none)"
    echo ""
    
    log_info "Applying new spec.pmm configuration to PXC cluster:"
    echo "  enabled: true"
    echo "  image: percona/pmm-client:$EXPECTED_VERSION"
    echo "  serverHost: $PMM_SERVICE  ← PMM client will connect to this service"
    echo "  resources:"
    echo "    requests: cpu=50m, memory=64Mi"
    echo "    limits: cpu=200m, memory=256Mi"
    echo ""
    log_info "Resource being patched: perconaxtradbcluster/$PXC_RESOURCE in namespace $NAMESPACE"
    echo ""
    
    local patch='{
      "spec": {
        "pmm": {
          "enabled": true,
          "image": "percona/pmm-client:'$EXPECTED_VERSION'",
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
        local new_image=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image}' 2>/dev/null || echo "")
        
        if [ "$new_enabled" = "true" ] && [ "$new_image" = "percona/pmm-client:$EXPECTED_VERSION" ]; then
            log_success "✓ PMM configuration verified in cluster spec"
        else
            log_warn "⚠ PMM configuration may not have been fully applied"
            log_warn "  enabled: $new_enabled (expected: true)"
            log_warn "  image: $new_image (expected: percona/pmm-client:$EXPECTED_VERSION)"
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
    log_info "Updating PMM client image in PXC cluster spec.pmm.image..."
    log_info "This ONLY changes PXC cluster configuration - does NOT modify PMM namespace"
    echo ""
    
    # Show current version
    local current_image=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image}' 2>/dev/null || echo "unknown")
    log_info "Current spec.pmm.image: $current_image"
    log_info "Target spec.pmm.image: percona/pmm-client:$EXPECTED_VERSION"
    log_info "Resource being patched: perconaxtradbcluster/$PXC_RESOURCE in namespace $NAMESPACE"
    echo ""
    
    local patch='{
      "spec": {
        "pmm": {
          "image": "percona/pmm-client:'$EXPECTED_VERSION'"
        }
      }
    }'
    
    local error_output
    if error_output=$(kubectl patch perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" --type=merge -p "$patch" 2>&1); then
        log_success "✓ Successfully updated PMM client version"
        echo "$error_output"
        VERSION_MISMATCH=false
        
        # Verify the patch was applied
        local new_image=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.image}' 2>/dev/null || echo "")
        if [ "$new_image" = "percona/pmm-client:$EXPECTED_VERSION" ]; then
            log_success "✓ Image update verified: $new_image"
        else
            log_warn "⚠ Image may not have been updated (current: $new_image)"
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
    log_info "Updating PXC cluster's spec.pmm.serverHost configuration..."
    log_info "This ONLY changes where PMM client connects to - does NOT modify PMM namespace"
    echo ""
    
    # Show current serverHost
    local current_host=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.serverHost}' 2>/dev/null || echo "not set")
    log_info "Current spec.pmm.serverHost: $current_host"
    log_info "Target spec.pmm.serverHost: $PMM_SERVICE"
    log_info "Resource being patched: perconaxtradbcluster/$PXC_RESOURCE in namespace $NAMESPACE"
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
        log_success "✓ Successfully updated spec.pmm.serverHost in PXC cluster"
        echo "$error_output"
        SERVERHOST_WRONG=false
        
        # Verify the patch was applied
        local new_host=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.pmm.serverHost}' 2>/dev/null || echo "")
        if [ "$new_host" = "$PMM_SERVICE" ]; then
            log_success "✓ spec.pmm.serverHost verified: $new_host"
            log_info "PMM client will now connect to '$new_host' service in pmm namespace"
        else
            log_warn "⚠ spec.pmm.serverHost may not have been updated (current: $new_host)"
        fi
        
        return 0
    else
        log_error "✗ Failed to update spec.pmm.serverHost in PXC cluster"
        log_error "kubectl patch error output:"
        echo "$error_output" | sed 's/^/  /'
        echo ""
        
        log_info "Try manually with:"
        echo "  kubectl patch perconaxtradbcluster $PXC_RESOURCE -n $NAMESPACE --type=merge -p '$patch'"
        echo ""
        
        return 1
    fi
}

fix_pmm_secret() {
    log_info "Adding PMM v3 authentication token to cluster secret..."
    log_info "This adds the 'pmmservertoken' key required by the operator (users.PMMServerToken)"
    echo ""
    
    local secret_name="${CLUSTER_NAME}-pxc-db-secrets"
    local internal_secret_name="internal-${CLUSTER_NAME}-pxc-db"
    
    # Check if we already have pmmservertoken
    local pmmservertoken=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.data.pmmservertoken}' 2>/dev/null || echo "")
    
    if [ -n "$pmmservertoken" ] && [ "$pmmservertoken" != "null" ]; then
        log_success "✓ 'pmmservertoken' key already exists in secret"
        return 0
    fi
    
    # Prompt for PMM API key
    log_info "You need to provide your PMM v3 server API key."
    log_info "Get it from: PMM UI → Configuration → API Keys"
    echo ""
    echo -n "Enter your PMM v3 API key (or 'skip' to do manually): "
    read -r PMM_API_KEY
    
    if [ "$PMM_API_KEY" = "skip" ] || [ -z "$PMM_API_KEY" ]; then
        log_info "Skipped. To add manually:"
        echo "  PMM_API_KEY='your-api-key-here'"
        echo "  kubectl patch secret $secret_name -n $NAMESPACE --type=merge -p \"{\\\"data\\\":{\\\"pmmservertoken\\\":\\\"\$(echo -n \\\$PMM_API_KEY | base64)\\\"}}\""
        return 1
    fi
    
    log_info "Adding 'pmmservertoken' key to secret: $secret_name"
    
    # Base64 encode the API key
    local encoded_key=$(echo -n "$PMM_API_KEY" | base64)
    
    # Patch the secret
    local error_output
    if error_output=$(kubectl patch secret "$secret_name" -n "$NAMESPACE" --type=merge -p "{\"data\":{\"pmmservertoken\":\"$encoded_key\"}}" 2>&1); then
        log_success "✓ Successfully added 'pmmservertoken' key to secret"
        echo ""
        
        # Verify the key was added
        local verify=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.data.pmmservertoken}' 2>/dev/null || echo "")
        if [ -n "$verify" ] && [ "$verify" != "null" ]; then
            local decoded_length=$(echo "$verify" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
            log_success "✓ Verified: 'pmmservertoken' key exists in secret (length: $decoded_length characters)"
            echo ""
            log_info "This satisfies the operator check at:"
            echo "  https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/app/statefulset/node.go#L386"
            echo "  if secret.Data[users.PMMServerToken] != nil && len(secret.Data[users.PMMServerToken]) > 0"
            echo "  Where users.PMMServerToken = 'pmmservertoken' (see users.go#L23)"
            echo ""
        else
            log_warn "⚠ Could not verify the key was added correctly"
        fi
        
        # Now sync the internal secret
        log_info "Syncing internal secret..."
        if kubectl get secret "$internal_secret_name" -n "$NAMESPACE" &>/dev/null; then
            log_info "Deleting internal secret to trigger operator resync..."
            if kubectl delete secret "$internal_secret_name" -n "$NAMESPACE" 2>&1; then
                log_success "✓ Internal secret deleted - operator will recreate it with new credentials"
            else
                log_warn "⚠ Could not delete internal secret - you may need to do this manually"
            fi
        else
            log_info "Internal secret doesn't exist yet - operator will create it"
        fi
        
        echo ""
        log_success "✓ PMM v3 authentication setup complete!"
        log_info "Next steps:"
        echo "  1. Wait a few seconds for the operator to sync secrets"
        echo "  2. Restart PXC pods to apply the new credentials:"
        echo "     kubectl delete pod -l app.kubernetes.io/component=pxc -n $NAMESPACE"
        echo ""
        
        return 0
    else
        log_error "✗ Failed to add 'pmmservertoken' key to secret"
        log_error "kubectl patch error output:"
        echo "$error_output" | sed 's/^/  /'
        echo ""
        
        log_info "Try manually with:"
        echo "  PMM_API_KEY='your-api-key-here'"
        echo "  kubectl patch secret $secret_name -n $NAMESPACE --type=merge -p \"{\\\"data\\\":{\\\"pmmservertoken\\\":\\\"\$(echo -n \\\$PMM_API_KEY | base64)\\\"}}\""
        echo ""
        
        return 1
    fi
}

perform_repairs() {
    log_header "PERFORMING REPAIRS"
    local repairs_made=0
    local repairs_failed=0
    
    # 1. Fix PMM secret if needed (MOST CRITICAL for PMM v3)
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_pmm_secret " ]]; then
        echo ""
        log_info "Repair 1/4: Add PMM v3 Authentication Token (CRITICAL)"
        echo -n "Add 'pmmserver' key to cluster secret? (yes/no) [yes]: "
        read -r FIX_SECRET
        FIX_SECRET=${FIX_SECRET:-yes}
        
        if [[ "$FIX_SECRET" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            if fix_pmm_secret; then
                ((repairs_made++))
            else
                ((repairs_failed++))
            fi
        else
            log_info "Skipped"
        fi
    fi
    
    # 2. Enable PMM if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " enable_pmm " ]]; then
        echo ""
        log_info "Repair 2/4: Enable PMM"
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
    
    # 3. Fix version if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_version " ]]; then
        echo ""
        log_info "Repair 3/4: Update PMM client version"
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
    
    # 4. Fix server host if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_serverhost " ]]; then
        echo ""
        log_info "Repair 4/4: Update PXC cluster's PMM serverHost configuration"
        echo -n "Set spec.pmm.serverHost to '$PMM_SERVICE' (only updates PXC cluster, not PMM namespace)? (yes/no) [yes]: "
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
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_pmm_secret " ]]; then
            echo "  1. Add PMM v3 authentication token ('pmmservertoken' key) to cluster secret (CRITICAL)"
        fi
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " enable_pmm " ]]; then
            echo "  2. Enable PMM in PXC cluster"
        fi
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_version " ]]; then
            echo "  3. Update PMM client version to $EXPECTED_VERSION"
        fi
        
        if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_serverhost " ]]; then
            echo "  4. Update PXC cluster PMM serverHost configuration to point to '$PMM_SERVICE'"
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
    
    # Automated analysis and specific recommendations
    log_header "AUTOMATED ANALYSIS"
    
    log_info "Analyzing findings to determine root cause..."
    echo ""
    
    # Determine most likely root cause
    if [ ${#ISSUES[@]} -gt 0 ] || [ ${#WARNINGS[@]} -gt 0 ]; then
        log_info "ROOT CAUSE ANALYSIS:"
        echo ""
        
        # Check for configuration issues
        if [ "$PMM_DISABLED" = true ]; then
            echo "  → PMM is DISABLED in PXC cluster configuration"
            echo "    Solution: Enable PMM using the repair function above"
            echo ""
        fi
        
        if [ "$VERSION_MISMATCH" = true ]; then
            echo "  → PMM client version mismatch detected"
            echo "    Current: $CURRENT_VERSION"
            echo "    Expected: $EXPECTED_VERSION"
            echo "    Solution: Update version using the repair function above"
            echo ""
        fi
        
        if [ "$SERVERHOST_WRONG" = true ]; then
            echo "  → PMM serverHost configuration is incorrect"
            echo "    Current: ${CURRENT_SERVERHOST:-<not set>}"
            echo "    Expected: $PMM_SERVICE"
            echo "    Solution: Update serverHost using the repair function above"
            echo ""
        fi
        
        # Check for authentication issues
        local has_auth_issue=false
        local has_sync_issue=false
        
        for issue in "${ISSUES[@]}"; do
            if [[ "$issue" =~ "authentication"|"PMM authentication"|"pmmserverkey"|"pmmserver"|"PMM v3 requires" ]]; then
                has_auth_issue=true
            fi
            if [[ "$issue" =~ "out of sync"|"secrets out of sync" ]]; then
                has_sync_issue=true
            fi
        done
        
        if [ "$has_sync_issue" = true ]; then
            echo "  → PMM SECRETS OUT OF SYNC"
            echo "    The operator's internal secrets don't match your cluster secrets."
            echo ""
            log_error "    ROOT CAUSE: Cluster secrets and internal secrets are desynchronized"
            echo ""
            echo "    This happens when you add/update PMM credentials after cluster creation."
            echo "    The operator maintains an internal copy that needs to be regenerated."
            echo ""
            echo "    How to fix:"
            echo "      1. Delete the internal secret (operator will recreate it):"
            echo "         kubectl delete secret internal-${CLUSTER_NAME}-pxc-db -n $NAMESPACE"
            echo ""
            echo "      2. Wait a few seconds for operator to recreate it"
            echo ""
            echo "      3. Restart PXC pods to apply changes:"
            echo "         kubectl delete pod -l app.kubernetes.io/component=pxc -n $NAMESPACE"
            echo ""
            echo "      4. Monitor operator logs:"
            echo "         kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=percona-xtradb-cluster-operator --tail=20 -f"
            echo ""
        elif [ "$has_auth_issue" = true ]; then
            echo "  → PMM v3 AUTHENTICATION FAILED"
            echo "    The PMM client cannot authenticate to the PMM v3 server."
            echo ""
            log_error "    ROOT CAUSE: Missing or invalid 'pmmservertoken' key in cluster secret"
            echo ""
            echo "    For PMM v3, the operator specifically checks for:"
            echo "      secret.Data[users.PMMServerToken]"
            echo "    where users.PMMServerToken = 'pmmservertoken'"
            echo ""
            echo "    Reference:"
            echo "      - Constant definition: https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/users/users.go#L23"
            echo "      - Operator check: https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/app/statefulset/node.go#L386"
            echo ""
            echo "    The secret '${CLUSTER_NAME}-pxc-db-secrets' MUST contain:"
            echo "      - Key: pmmservertoken (NOT pmmserverkey, NOT pmmserver)"
            echo "      - Value: Base64-encoded PMM v3 API token (from PMM web UI)"
            echo ""
            echo "    How to fix:"
            echo "      1. Get your PMM v3 server API token:"
            echo "         • Log into PMM v3 web UI"
            echo "         • Navigate to Configuration → API Keys"
            echo "         • Generate a new API key (or use existing)"
            echo ""
            echo "      2. Add the token to your cluster secret with the CORRECT key name:"
            echo "         PMM_API_KEY='your-api-key-here'"
            echo "         kubectl patch secret ${CLUSTER_NAME}-pxc-db-secrets -n $NAMESPACE --type=merge -p \"{\\\"data\\\":{\\\"pmmservertoken\\\":\\\"\$(echo -n \\\$PMM_API_KEY | base64)\\\"}}\""
            echo ""
            echo "      3. Delete internal secret to trigger resync:"
            echo "         kubectl delete secret internal-${CLUSTER_NAME}-pxc-db -n $NAMESPACE"
            echo ""
            echo "      4. Restart PXC pods to apply:"
            echo "         kubectl delete pod -l app.kubernetes.io/component=pxc -n $NAMESPACE"
            echo ""
            echo "    Or use the automated repair function offered above."
            echo ""
        fi
        
        # Check for DNS/connectivity issues
        local has_dns_issue=false
        local has_connectivity_issue=false
        for issue in "${ISSUES[@]}"; do
            if [[ "$issue" =~ "DNS" ]]; then
                has_dns_issue=true
            fi
            if [[ "$issue" =~ "connect\|TCP\|HTTPS\|443" ]]; then
                has_connectivity_issue=true
            fi
        done
        
        if [ "$has_dns_issue" = true ]; then
            echo "  → DNS resolution is FAILING"
            echo "    The PMM client cannot resolve '$PMM_SERVICE'"
            echo "    Possible causes:"
            echo "      - CoreDNS not functioning properly"
            echo "      - PMM service does not exist"
            echo "      - Incorrect service FQDN"
            echo "    Check: kubectl get svc -n $PMM_NAMESPACE"
            echo ""
        fi
        
        if [ "$has_connectivity_issue" = true ]; then
            echo "  → Network connectivity is FAILING"
            echo "    The PMM client cannot reach PMM server on port 443"
            echo "    Possible causes:"
            echo "      - PMM server not running"
            echo "      - Network policy blocking traffic"
            echo "      - Service has no endpoints (no backend pods)"
            echo "    Check: kubectl get pods -n $PMM_NAMESPACE"
            echo ""
        fi
        
        # Check for PMM server issues
        for issue in "${ISSUES[@]}"; do
            if [[ "$issue" =~ "PMM server" ]]; then
                echo "  → PMM SERVER is NOT RUNNING"
                echo "    No PMM server pods found in namespace '$PMM_NAMESPACE'"
                echo "    Solution: Deploy PMM server before configuring PMM client"
                echo "    Verify: kubectl get pods -n $PMM_NAMESPACE"
                echo ""
            fi
        done
        
        # Check for operator issues
        for issue in "${ISSUES[@]}"; do
            if [[ "$issue" =~ "Operator" ]]; then
                echo "  → PERCONA OPERATOR is NOT RUNNING"
                echo "    The operator is required to manage PMM client configuration"
                echo "    Solution: Verify operator deployment"
                echo "    Check: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=percona-xtradb-cluster-operator"
                echo ""
            fi
        done
        
        # Summarize next steps
        log_info "NEXT STEPS:"
        echo ""
        
        if [ "$PMM_DISABLED" = true ] || [ "$VERSION_MISMATCH" = true ] || [ "$SERVERHOST_WRONG" = true ]; then
            echo "  1. Apply the configuration fixes offered above"
            echo "  2. Wait for PXC pods to restart (operator will handle this)"
            echo "  3. Re-run diagnostics to verify"
            echo ""
        fi
        
        if [ "$has_dns_issue" = true ] || [ "$has_connectivity_issue" = true ]; then
            echo "  1. Verify PMM server is running:"
            echo "     kubectl get pods -n $PMM_NAMESPACE"
            echo ""
            echo "  2. Verify PMM service exists and has endpoints:"
            echo "     kubectl get svc,endpoints -n $PMM_NAMESPACE"
            echo ""
            echo "  3. If PMM server is not deployed, deploy it first"
            echo ""
        fi
        
        for issue in "${ISSUES[@]}"; do
            if [[ "$issue" =~ "Network policy" ]]; then
                echo "  Network policies detected - review them:"
                echo "     kubectl get networkpolicies -n $NAMESPACE -o yaml"
                echo "     Ensure traffic to $PMM_NAMESPACE namespace is allowed"
                echo ""
            fi
        done
    else
        log_success "No critical issues detected!"
        echo ""
        log_info "PMM client appears to be properly configured."
        log_info "If metrics are not appearing in PMM dashboard:"
        echo "  1. Wait a few minutes for metrics to start flowing"
        echo "  2. Verify PMM dashboard is accessible"
        echo "  3. Check PMM server logs for any issues"
        echo ""
    fi
    
    log_info "For more information:"
    log_info "  - PMM docs: https://docs.percona.com/percona-monitoring-and-management/"
    log_info "  - Operator docs: https://docs.percona.com/percona-operator-for-mysql/pxc/"
    echo ""
}

# Run checks
check_prerequisites
run_diagnostics
run_summary_and_repair


#!/usr/bin/env bash
#
# Database Emergency Diagnostic CLI
# Detects which disaster scenario is currently occurring
#
# Usage: ./detect-scenario.sh --namespace percona
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

# Global state
NAMESPACE=""
CLUSTER_NAME=""
VERBOSE=false
JSON_OUTPUT=false
ENVIRONMENT="on-prem"

# Diagnostic results
declare -a SCENARIOS=()
declare -a INDICATORS=()

# Logging functions
log() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "$1"
    fi
}

log_step() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "  ${CYAN}-> $1${RESET}"
    fi
}

log_success() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "  ${GREEN}[OK] $1${RESET}"
    fi
}

log_warn() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "  ${YELLOW}[!] $1${RESET}"
    fi
}

log_error() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "  ${RED}[ERROR] $1${RESET}"
    fi
}

log_detail() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "    ${GRAY}$1${RESET}"
    fi
}

# Run kubectl with timeout
run_kubectl() {
    local timeout="${KUBECTL_TIMEOUT:-30}"
    if timeout "$timeout" kubectl "$@" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Usage
usage() {
    cat << EOF
Database Emergency Diagnostic CLI

Usage: $(basename "$0") [OPTIONS]

Required:
  -n, --namespace NAME    Kubernetes namespace to inspect

Options:
  -c, --cluster-name NAME PXC cluster name (optional, auto-detected)
  -v, --verbose           Show detailed command output
      --json              Output results as JSON
  -h, --help              Show this help message

Examples:
  $(basename "$0") --namespace percona
  $(basename "$0") -n percona -c cluster1 --verbose

Requirements:
  - KUBECONFIG must be set or ~/.kube/config must exist
  - kubectl must be installed and configured
EOF
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -c|--cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done

    if [[ -z "$NAMESPACE" ]]; then
        echo "Error: --namespace is required" >&2
        echo "" >&2
        usage
    fi
}

# Check prerequisites
check_prerequisites() {
    # Check KUBECONFIG
    if [[ -z "${KUBECONFIG:-}" ]] && [[ ! -f "${HOME}/.kube/config" ]]; then
        echo "Error: KUBECONFIG environment variable must be set or ~/.kube/config must exist" >&2
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &>/dev/null; then
        echo "Error: kubectl is not installed or not in PATH" >&2
        exit 1
    fi
}

# Add scenario match
add_scenario() {
    local confidence="$1"
    local scenario="$2"
    local file="$3"
    shift 3
    local indicators=("$@")
    
    SCENARIOS+=("${confidence}|${scenario}|${file}|$(IFS=';'; echo "${indicators[*]}")")
}

# Check API server
check_api_server() {
    log_step "Checking Kubernetes API server connectivity..."
    
    if run_kubectl cluster-info &>/dev/null; then
        log_success "API server is responsive"
        return 0
    else
        log_error "API server is not responding"
        return 1
    fi
}

# Detect environment (EKS vs on-prem)
detect_environment() {
    log_step "Detecting environment..."
    
    local context
    context=$(kubectl config current-context 2>/dev/null || echo "")
    
    if [[ "$context" == *"eks"* ]] || [[ "$context" == *"aws"* ]] || [[ "$context" == *"amazon"* ]]; then
        ENVIRONMENT="eks"
    else
        ENVIRONMENT="on-prem"
    fi
    
    log_detail "Environment: $ENVIRONMENT"
}

# Check DNS
check_dns() {
    log_step "Checking DNS resolution..."
    
    # Try to resolve kubernetes.default
    if run_kubectl run dns-test --rm -i --restart=Never \
        --image=busybox:1.28 -n "$NAMESPACE" \
        -- nslookup kubernetes.default &>/dev/null; then
        log_success "DNS resolution working"
        return 0
    else
        # Clean up pod if it wasn't deleted
        kubectl delete pod dns-test -n "$NAMESPACE" --ignore-not-found &>/dev/null || true
        log_warn "DNS resolution may have issues"
        return 1
    fi
}

# Check PXC pod status
check_pod_status() {
    log_step "Checking PXC pod status in namespace $NAMESPACE..."
    
    local pods_json
    pods_json=$(run_kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc -o json 2>/dev/null || echo '{"items":[]}')
    
    local total running crashloop pending oom_killed
    total=$(echo "$pods_json" | jq '.items | length')
    running=$(echo "$pods_json" | jq '[.items[] | select(.status.phase == "Running")] | length')
    crashloop=$(echo "$pods_json" | jq '[.items[].status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff")] | length')
    pending=$(echo "$pods_json" | jq '[.items[] | select(.status.phase == "Pending")] | length')
    oom_killed=$(echo "$pods_json" | jq '[.items[].status.containerStatuses[]? | select(.state.terminated.reason == "OOMKilled")] | length')
    
    log_detail "Pods: $running/$total running, $crashloop crashloop, $oom_killed OOM"
    
    # Export for scenario detection
    POD_TOTAL=$total
    POD_RUNNING=$running
    POD_CRASHLOOP=$crashloop
    POD_PENDING=$pending
    POD_OOM=$oom_killed
    POD_ALL_DOWN=$( [[ $running -eq 0 ]] && [[ $total -gt 0 ]] && echo "true" || echo "false" )
    
    # Get container errors
    POD_ERRORS=$(echo "$pods_json" | jq -r '.items[] | .metadata.name as $name | .status.containerStatuses[]? | select(.state.waiting.reason != null and .state.waiting.reason != "ContainerCreating" and .state.waiting.reason != "PodInitializing") | "\($name): \(.state.waiting.reason)"' | head -5)
}

# Check cluster quorum
check_cluster_quorum() {
    log_step "Checking Galera cluster quorum..."
    
    local pod_name
    pod_name=$(run_kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc \
        -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running 2>/dev/null || echo "")
    
    QUORUM_REACHABLE=false
    QUORUM_HAS_QUORUM=false
    QUORUM_STATUS="unknown"
    QUORUM_SIZE=0
    
    if [[ -z "$pod_name" ]]; then
        log_warn "No running PXC pods found to check quorum"
        return 1
    fi
    
    QUORUM_REACHABLE=true
    
    local status_output
    status_output=$(run_kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
        "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_cluster_size');" 2>/dev/null || echo "")
    
    if [[ "$status_output" == *"Primary"* ]]; then
        QUORUM_HAS_QUORUM=true
        QUORUM_STATUS="Primary"
    elif [[ "$status_output" == *"non-Primary"* ]]; then
        QUORUM_STATUS="non-Primary"
    fi
    
    QUORUM_SIZE=$(echo "$status_output" | grep -oP 'wsrep_cluster_size\s+\K\d+' || echo "0")
    
    log_detail "Cluster: $QUORUM_SIZE nodes, status=$QUORUM_STATUS"
}

# Check Kubernetes nodes
check_nodes() {
    log_step "Checking Kubernetes node status..."
    
    local nodes_json
    nodes_json=$(run_kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')
    
    NODE_TOTAL=$(echo "$nodes_json" | jq '.items | length')
    NODE_READY=$(echo "$nodes_json" | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True"))] | length')
    NODE_NOT_READY=$((NODE_TOTAL - NODE_READY))
    NODE_DISK_PRESSURE=$(echo "$nodes_json" | jq '[.items[] | select(.status.conditions[] | select(.type == "DiskPressure" and .status == "True"))] | length')
    NODE_MEMORY_PRESSURE=$(echo "$nodes_json" | jq '[.items[] | select(.status.conditions[] | select(.type == "MemoryPressure" and .status == "True"))] | length')
    NODE_UNREACHABLE=$(echo "$nodes_json" | jq -r '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True")) | .metadata.name] | join(", ")')
    
    log_detail "Nodes: $NODE_READY/$NODE_TOTAL ready, $NODE_DISK_PRESSURE disk pressure, $NODE_MEMORY_PRESSURE memory pressure"
}

# Check Percona Operator
check_operator() {
    log_step "Checking Percona Operator status..."
    
    OPERATOR_RUNNING=false
    OPERATOR_COUNT=0
    
    # Try multiple possible namespaces and labels
    local namespaces=("percona-operator" "$NAMESPACE" "default")
    local labels=("app.kubernetes.io/name=percona-xtradb-cluster-operator" "name=percona-xtradb-cluster-operator")
    
    for ns in "${namespaces[@]}"; do
        for label in "${labels[@]}"; do
            local pods_json
            pods_json=$(run_kubectl get pods -n "$ns" -l "$label" -o json 2>/dev/null || echo '{"items":[]}')
            
            local count
            count=$(echo "$pods_json" | jq '.items | length')
            
            if [[ $count -gt 0 ]]; then
                OPERATOR_COUNT=$count
                local running
                running=$(echo "$pods_json" | jq '[.items[] | select(.status.phase == "Running")] | length')
                if [[ $running -gt 0 ]]; then
                    OPERATOR_RUNNING=true
                fi
                break 2
            fi
        done
    done
    
    if [[ "$OPERATOR_RUNNING" == "true" ]]; then
        log_success "Operator is running"
    else
        log_warn "Operator is not running"
    fi
}

# Check service endpoints
check_services() {
    log_step "Checking proxy service endpoints..."
    
    SERVICE_HAS_ENDPOINTS=false
    SERVICE_ENDPOINT_COUNT=0
    SERVICE_PROXY_TYPE="unknown"
    
    # Check ProxySQL
    local ep_json
    ep_json=$(run_kubectl get endpoints -n "$NAMESPACE" -l app.kubernetes.io/component=proxysql -o json 2>/dev/null || echo '{"items":[]}')
    
    local count
    count=$(echo "$ep_json" | jq '[.items[].subsets[]?.addresses[]?] | length')
    
    if [[ $count -gt 0 ]]; then
        SERVICE_PROXY_TYPE="proxysql"
        SERVICE_ENDPOINT_COUNT=$count
        SERVICE_HAS_ENDPOINTS=true
    else
        # Check HAProxy
        ep_json=$(run_kubectl get endpoints -n "$NAMESPACE" -l app.kubernetes.io/component=haproxy -o json 2>/dev/null || echo '{"items":[]}')
        count=$(echo "$ep_json" | jq '[.items[].subsets[]?.addresses[]?] | length')
        
        if [[ $count -gt 0 ]]; then
            SERVICE_PROXY_TYPE="haproxy"
            SERVICE_ENDPOINT_COUNT=$count
            SERVICE_HAS_ENDPOINTS=true
        fi
    fi
    
    log_detail "Proxy: $SERVICE_PROXY_TYPE, $SERVICE_ENDPOINT_COUNT endpoints"
}

# Check PVC status
check_pvcs() {
    log_step "Checking PVC status and disk usage..."
    
    local pvc_json
    pvc_json=$(run_kubectl get pvc -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
    
    PVC_TOTAL=$(echo "$pvc_json" | jq '.items | length')
    PVC_BOUND=$(echo "$pvc_json" | jq '[.items[] | select(.status.phase == "Bound")] | length')
    PVC_PENDING=$(echo "$pvc_json" | jq '[.items[] | select(.status.phase == "Pending")] | length')
    PVC_ISSUES=$(echo "$pvc_json" | jq -r '.items[] | select(.status.phase == "Pending") | "PVC \(.metadata.name) is pending"')
    
    # Check disk usage on running pods
    local pod_name
    pod_name=$(run_kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc \
        -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running 2>/dev/null || echo "")
    
    DISK_USAGE_HIGH=""
    if [[ -n "$pod_name" ]]; then
        local df_output
        df_output=$(run_kubectl exec -n "$NAMESPACE" "$pod_name" -- df -h /var/lib/mysql 2>/dev/null || echo "")
        
        local used_percent
        used_percent=$(echo "$df_output" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
        
        if [[ -n "$used_percent" ]] && [[ $used_percent -gt 85 ]]; then
            DISK_USAGE_HIGH="$pod_name: ${used_percent}% disk used"
        fi
    fi
    
    log_detail "PVCs: $PVC_BOUND/$PVC_TOTAL bound, $PVC_PENDING pending"
}

# Check replication status
check_replication() {
    log_step "Checking replication status..."
    
    REPL_CONFIGURED=false
    REPL_IO_RUNNING=false
    REPL_SQL_RUNNING=false
    REPL_SECONDS_BEHIND=""
    REPL_LAST_ERROR=""
    
    local pod_name
    pod_name=$(run_kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc \
        -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running 2>/dev/null || echo "")
    
    if [[ -z "$pod_name" ]]; then
        log_detail "Replication: No running pods to check"
        return
    fi
    
    local repl_output
    repl_output=$(run_kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G" 2>/dev/null || \
        run_kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G" 2>/dev/null || echo "")
    
    if [[ "$repl_output" == *"Replica_IO_Running"* ]] || [[ "$repl_output" == *"Slave_IO_Running"* ]]; then
        REPL_CONFIGURED=true
        
        if [[ "$repl_output" == *"_IO_Running: Yes"* ]]; then
            REPL_IO_RUNNING=true
        fi
        
        if [[ "$repl_output" == *"_SQL_Running: Yes"* ]]; then
            REPL_SQL_RUNNING=true
        fi
        
        REPL_SECONDS_BEHIND=$(echo "$repl_output" | grep -oP 'Seconds_Behind_\w+:\s+\K\d+' | head -1 || echo "")
        REPL_LAST_ERROR=$(echo "$repl_output" | grep -oP 'Last_(?:IO_)?Error:\s+\K.+' | head -1 || echo "")
        
        log_detail "Replication: IO=$REPL_IO_RUNNING, SQL=$REPL_SQL_RUNNING, Lag=${REPL_SECONDS_BEHIND}s"
    else
        log_detail "Replication: Not configured"
    fi
}

# Check backup status
check_backups() {
    log_step "Checking backup status..."
    
    BACKUP_LAST_TIME=""
    BACKUP_FAILING=false
    BACKUP_ERRORS=""
    
    local backup_json
    backup_json=$(run_kubectl get perconaxtradbclusterbackup -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
    
    local count
    count=$(echo "$backup_json" | jq '.items | length')
    
    if [[ $count -gt 0 ]]; then
        # Get latest backup
        BACKUP_LAST_TIME=$(echo "$backup_json" | jq -r '[.items | sort_by(.metadata.creationTimestamp) | reverse | .[0]] | .[0].metadata.creationTimestamp // "none"')
        
        local latest_state
        latest_state=$(echo "$backup_json" | jq -r '[.items | sort_by(.metadata.creationTimestamp) | reverse | .[0]] | .[0].status.state // "unknown"')
        
        if [[ "$latest_state" == "Failed" ]]; then
            BACKUP_FAILING=true
            BACKUP_ERRORS=$(echo "$backup_json" | jq -r '[.items | sort_by(.metadata.creationTimestamp) | reverse | .[0]] | .[0].status.error // "unknown error"')
        fi
        
        log_detail "Last backup: $BACKUP_LAST_TIME"
    else
        log_detail "Backups: No backup resources found"
    fi
}

# Detect scenarios based on gathered data
detect_scenarios() {
    # API server down - most critical (already handled in main)
    
    # All pods down - site outage
    if [[ "$POD_ALL_DOWN" == "true" ]]; then
        add_scenario "CRITICAL" \
            "Primary DC power/cooling outage (site down)" \
            "primary-dc-power-cooling-outage-site-down.md" \
            "All $POD_TOTAL PXC pods are down"
    fi
    
    # Quorum loss
    if [[ "$QUORUM_REACHABLE" == "true" ]] && [[ "$QUORUM_HAS_QUORUM" == "false" ]]; then
        add_scenario "CRITICAL" \
            "Cluster loses quorum (multiple PXC pods down)" \
            "cluster-loses-quorum.md" \
            "Cluster status: $QUORUM_STATUS" "Cluster size: $QUORUM_SIZE"
    fi
    
    # OOM kills
    if [[ $POD_OOM -gt 0 ]]; then
        add_scenario "HIGH" \
            "Memory exhaustion causing OOM kills" \
            "memory-exhaustion-causing-oom-kills-out-of-memory.md" \
            "$POD_OOM pod(s) killed by OOM"
    fi
    
    # Single pod failure with CrashLoopBackOff
    if [[ $POD_CRASHLOOP -ge 1 ]] && [[ "$QUORUM_HAS_QUORUM" == "true" ]] && [[ $POD_RUNNING -ge 2 ]]; then
        add_scenario "HIGH" \
            "Single MySQL pod failure (container crash / OOM)" \
            "single-mysql-pod-failure.md" \
            "$POD_CRASHLOOP pod(s) in CrashLoopBackOff"
    fi
    
    # Node failure
    if [[ $NODE_NOT_READY -ge 1 ]]; then
        add_scenario "HIGH" \
            "Kubernetes worker node failure (VM host crash)" \
            "kubernetes-worker-node-failure.md" \
            "$NODE_NOT_READY node(s) not ready" "${NODE_UNREACHABLE:+Nodes: $NODE_UNREACHABLE}"
    fi
    
    # Disk pressure on nodes
    if [[ $NODE_DISK_PRESSURE -gt 0 ]]; then
        add_scenario "HIGH" \
            "Database disk space exhaustion (data directory)" \
            "database-disk-space-exhaustion.md" \
            "$NODE_DISK_PRESSURE node(s) with disk pressure"
    fi
    
    # Memory pressure on nodes
    if [[ $NODE_MEMORY_PRESSURE -gt 0 ]]; then
        add_scenario "MEDIUM" \
            "Memory exhaustion causing OOM kills" \
            "memory-exhaustion-causing-oom-kills-out-of-memory.md" \
            "$NODE_MEMORY_PRESSURE node(s) with memory pressure"
    fi
    
    # High disk usage
    if [[ -n "$DISK_USAGE_HIGH" ]]; then
        add_scenario "HIGH" \
            "Database disk space exhaustion (data directory)" \
            "database-disk-space-exhaustion.md" \
            "$DISK_USAGE_HIGH"
    fi
    
    # PVC pending
    if [[ $PVC_PENDING -gt 0 ]]; then
        add_scenario "HIGH" \
            "Storage PVC corruption or provisioning failure" \
            "storage-pvc-corruption.md" \
            "$PVC_PENDING PVC(s) pending"
    fi
    
    # Operator not running
    if [[ "$OPERATOR_RUNNING" == "false" ]] && [[ $POD_TOTAL -gt 0 ]]; then
        add_scenario "MEDIUM" \
            "Percona Operator / CRD misconfiguration (bad rollout)" \
            "percona-operator-crd-misconfiguration.md" \
            "Percona Operator is not running"
    fi
    
    # Service/endpoint issues
    if [[ "$SERVICE_HAS_ENDPOINTS" == "false" ]] && [[ $POD_RUNNING -gt 0 ]]; then
        add_scenario "HIGH" \
            "Ingress/VIP failure (HAProxy/ProxySQL service unreachable)" \
            "ingress-vip-failure.md" \
            "$SERVICE_PROXY_TYPE has no healthy endpoints" \
            "$POD_RUNNING PXC pods running but not in endpoint list"
    fi
    
    # Replication issues
    if [[ "$REPL_CONFIGURED" == "true" ]]; then
        if [[ "$REPL_IO_RUNNING" == "false" ]] || [[ "$REPL_SQL_RUNNING" == "false" ]]; then
            add_scenario "HIGH" \
                "Both DCs up but replication stops (broken channel)" \
                "both-dcs-up-but-replication-stops-broken-channel.md" \
                "IO thread: $REPL_IO_RUNNING" "SQL thread: $REPL_SQL_RUNNING" "${REPL_LAST_ERROR:+Error: $REPL_LAST_ERROR}"
        elif [[ -n "$REPL_SECONDS_BEHIND" ]] && [[ $REPL_SECONDS_BEHIND -gt 300 ]]; then
            add_scenario "MEDIUM" \
                "Primary DC network partition from Secondary (WAN cut)" \
                "primary-dc-network-partition-from-secondary-wan-cut.md" \
                "Replication lag: ${REPL_SECONDS_BEHIND} seconds behind"
        fi
    fi
    
    # Backup failures
    if [[ "$BACKUP_FAILING" == "true" ]]; then
        add_scenario "MEDIUM" \
            "Backups complete but are non-restorable (silent failure)" \
            "backups-complete-but-are-non-restorable-silent-failure.md" \
            "${BACKUP_ERRORS:-Latest backup failed}"
    fi
}

# Print results
print_results() {
    log ""
    log "${YELLOW}${BOLD}$(printf '=%.0s' {1..50})${RESET}"
    log "${YELLOW}${BOLD}DIAGNOSTIC RESULTS${RESET}"
    log "${YELLOW}${BOLD}$(printf '=%.0s' {1..50})${RESET}"
    log ""
    
    if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
        log "${GREEN}${BOLD}No critical issues detected${RESET}"
        log ""
        log "If you are experiencing issues, check:"
        log "  - Application logs"
        log "  - Network connectivity"
        log "  - Authentication/credentials"
        log "  - Recent changes or deployments"
        return 0
    fi
    
    log "${RED}${BOLD}DETECTED ${#SCENARIOS[@]} POTENTIAL SCENARIO(S):${RESET}"
    log ""
    
    # Sort by confidence (CRITICAL first)
    IFS=$'\n' sorted=($(printf '%s\n' "${SCENARIOS[@]}" | sort -t'|' -k1,1))
    unset IFS
    
    local i=1
    for scenario in "${sorted[@]}"; do
        IFS='|' read -r confidence name file indicators_str <<< "$scenario"
        
        local color
        case "$confidence" in
            CRITICAL) color="$RED" ;;
            HIGH) color="$YELLOW" ;;
            *) color="$CYAN" ;;
        esac
        
        log "${color}${BOLD}$i. [$confidence] $name${RESET}"
        log "${GRAY}   Recovery Doc: recovery_processes/$ENVIRONMENT/$file${RESET}"
        
        if [[ -n "$indicators_str" ]]; then
            log "${GRAY}   Indicators:${RESET}"
            IFS=';' read -ra inds <<< "$indicators_str"
            for ind in "${inds[@]}"; do
                [[ -n "$ind" ]] && log "${GRAY}     - $ind${RESET}"
            done
        fi
        log ""
        ((i++))
    done
    
    log "${CYAN}${BOLD}NEXT STEPS:${RESET}"
    log "1. Review the recovery documentation in dr-dashboard/recovery_processes/$ENVIRONMENT/"
    log "2. Open the Database Emergency Kit dashboard: http://localhost:8080"
    log "3. Switch to '${ENVIRONMENT^^}' environment in the dashboard"
    log "4. Follow the recovery steps for the matching scenario(s)"
    log "5. Contact on-call DBA if needed"
    log ""
    
    return 1
}

# Print JSON output
print_json() {
    local scenarios_json="["
    local first=true
    
    for scenario in "${SCENARIOS[@]}"; do
        IFS='|' read -r confidence name file indicators_str <<< "$scenario"
        
        [[ "$first" == "true" ]] || scenarios_json+=","
        first=false
        
        local indicators_json="["
        local first_ind=true
        IFS=';' read -ra inds <<< "$indicators_str"
        for ind in "${inds[@]}"; do
            if [[ -n "$ind" ]]; then
                [[ "$first_ind" == "true" ]] || indicators_json+=","
                first_ind=false
                indicators_json+="\"$(echo "$ind" | sed 's/"/\\"/g')\""
            fi
        done
        indicators_json+="]"
        
        scenarios_json+="{\"confidence\":\"$confidence\",\"scenario\":\"$name\",\"file\":\"$file\",\"indicators\":$indicators_json}"
    done
    
    scenarios_json+="]"
    
    cat << EOF
{
  "environment": "$ENVIRONMENT",
  "namespace": "$NAMESPACE",
  "scenarios": $scenarios_json,
  "state": {
    "pods": {"total": $POD_TOTAL, "running": $POD_RUNNING, "crashloop": $POD_CRASHLOOP, "oomKilled": $POD_OOM},
    "quorum": {"hasQuorum": $QUORUM_HAS_QUORUM, "clusterSize": $QUORUM_SIZE, "status": "$QUORUM_STATUS"},
    "nodes": {"total": $NODE_TOTAL, "ready": $NODE_READY, "notReady": $NODE_NOT_READY},
    "operator": {"running": $OPERATOR_RUNNING},
    "services": {"hasEndpoints": $SERVICE_HAS_ENDPOINTS, "endpointCount": $SERVICE_ENDPOINT_COUNT}
  }
}
EOF
}

# Main
main() {
    parse_args "$@"
    check_prerequisites
    
    # Get MySQL password from environment or secret
    if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
        MYSQL_ROOT_PASSWORD=$(kubectl get secret -n "$NAMESPACE" \
            -l app.kubernetes.io/component=pxc \
            -o jsonpath='{.items[0].data.root}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    log ""
    log "${RED}${BOLD}DATABASE EMERGENCY DIAGNOSTIC${RESET}"
    log "${RED}$(printf '=%.0s' {1..50})${RESET}"
    log ""
    log "${CYAN}Namespace: $NAMESPACE${RESET}"
    log ""
    
    # Check API server first
    log "${YELLOW}${BOLD}[1/9] Infrastructure Checks${RESET}"
    if ! check_api_server; then
        add_scenario "CRITICAL" \
            "Kubernetes control plane outage (API server down)" \
            "kubernetes-control-plane-outage-api-server-down.md" \
            "API server not responding to kubectl commands"
        
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            print_json
        else
            print_results
        fi
        exit 1
    fi
    
    detect_environment
    
    log "${YELLOW}${BOLD}[2/9] Pod Status${RESET}"
    check_pod_status
    
    log "${YELLOW}${BOLD}[3/9] Cluster Quorum${RESET}"
    check_cluster_quorum
    
    log "${YELLOW}${BOLD}[4/9] Kubernetes Nodes${RESET}"
    check_nodes
    
    log "${YELLOW}${BOLD}[5/9] Percona Operator${RESET}"
    check_operator
    
    log "${YELLOW}${BOLD}[6/9] Service Endpoints${RESET}"
    check_services
    
    log "${YELLOW}${BOLD}[7/9] Storage (PVCs)${RESET}"
    check_pvcs
    
    log "${YELLOW}${BOLD}[8/9] Replication${RESET}"
    check_replication
    
    log "${YELLOW}${BOLD}[9/9] Backups${RESET}"
    check_backups
    
    # Detect scenarios
    detect_scenarios
    
    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        print_json
    else
        print_results
    fi
    
    [[ ${#SCENARIOS[@]} -eq 0 ]] && exit 0 || exit 1
}

main "$@"


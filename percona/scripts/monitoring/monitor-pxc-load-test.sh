#!/bin/bash
# Percona XtraDB Cluster Load Testing Monitor
# Run this script during load testing to monitor cluster health

set -euo pipefail

# Configuration
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
INTERVAL="${INTERVAL:-5}"  # seconds between checks
OUTPUT_DIR="${OUTPUT_DIR:-pxc-monitoring-$(date +%Y%m%d-%H%M%S)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Create output directory
mkdir -p "$OUTPUT_DIR"

# MySQL connection options
MYSQL_OPTS="-h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER"
if [ -n "$MYSQL_PASSWORD" ]; then
    MYSQL_OPTS="$MYSQL_OPTS -p$MYSQL_PASSWORD"
fi

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Check if mysql client is available
check_mysql_client() {
    if ! command -v mysql &> /dev/null; then
        error "MySQL client is not installed"
        error "Install it with: sudo apt-get install mysql-client"
        exit 1
    fi
}

check_mysql_connection() {
    local error_output
    error_output=$(mysql $MYSQL_OPTS -e "SELECT 1;" 2>&1)
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Cannot connect to MySQL at $MYSQL_HOST:$MYSQL_PORT"
        error "MySQL error: $(echo "$error_output" | head -n 1)"
        error "Connection string: mysql -h $MYSQL_HOST -P $MYSQL_PORT -u $MYSQL_USER"
        error ""
        error "Troubleshooting:"
        error "  1. Check if MySQL is running: telnet $MYSQL_HOST $MYSQL_PORT"
        error "  2. Verify credentials are correct"
        error "  3. Check firewall rules"
        error "  4. Ensure MySQL accepts remote connections (bind-address in my.cnf)"
        exit 1
    fi
}

# Run a query and format output
run_query() {
    local query="$1"
    local title="$2"

    echo "=== $title ==="
    if ! mysql $MYSQL_OPTS -e "$query" 2>/dev/null; then
        echo "Query failed"
    fi
    echo
}

# Monitor cluster status
monitor_cluster_status() {
    log "Monitoring Cluster Status..."

    # Cluster overview
    run_query "
    SELECT
        'Cluster Size' as Metric,
        VARIABLE_VALUE as Value,
        CASE WHEN VARIABLE_VALUE = '3' THEN '✅ GOOD' ELSE '❌ BAD' END as Status
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'wsrep_cluster_size'
    UNION ALL
    SELECT
        'Cluster Status',
        VARIABLE_VALUE,
        CASE WHEN VARIABLE_VALUE = 'Primary' THEN '✅ GOOD' ELSE '❌ BAD' END
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'wsrep_cluster_status'
    UNION ALL
    SELECT
        'Node Ready',
        VARIABLE_VALUE,
        CASE WHEN VARIABLE_VALUE = 'ON' THEN '✅ GOOD' ELSE '❌ BAD' END
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'wsrep_ready'
    UNION ALL
    SELECT
        'Flow Control Paused',
        VARIABLE_VALUE,
        CASE WHEN CAST(VARIABLE_VALUE AS DECIMAL) > 0 THEN '❌ FLOW CONTROL ACTIVE' ELSE '✅ GOOD' END
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'wsrep_flow_control_paused';" "CLUSTER HEALTH OVERVIEW"

    # Node status
    run_query "
    SELECT
        node_index as 'Node #',
        name as 'Node Name',
        address as 'Address',
        status as 'Status'
    FROM information_schema.wsrep_cluster_members
    ORDER BY node_index;" "CLUSTER NODES"

    # Queue status
    run_query "
    SELECT
        'Local Recv Queue' as Queue,
        VARIABLE_VALUE as Size,
        CASE WHEN CAST(VARIABLE_VALUE AS UNSIGNED) > 0 THEN '⚠️  BACKLOG' ELSE '✅ GOOD' END as Status
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'wsrep_local_recv_queue'
    UNION ALL
    SELECT
        'Local Send Queue',
        VARIABLE_VALUE,
        CASE WHEN CAST(VARIABLE_VALUE AS UNSIGNED) > 0 THEN '⚠️  BACKLOG' ELSE '✅ GOOD' END
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'wsrep_local_send_queue';" "REPLICATION QUEUES"
}

# Monitor performance metrics
monitor_performance() {
    log "Monitoring Performance Metrics..."

    # Connections
    run_query "
    SELECT
        'Current Connections' as Metric,
        COUNT(*) as Value
    FROM information_schema.processlist
    UNION ALL
    SELECT
        'Active Threads',
        COUNT(*)
    FROM performance_schema.threads
    WHERE PROCESSLIST_STATE IS NOT NULL
    UNION ALL
    SELECT
        'Max Connections',
        @@max_connections;" "CONNECTIONS & THREADS"

    # Running queries
    run_query "
    SELECT
        COUNT(*) as 'Running Queries',
        SUM(TIME) as 'Total Query Time (sec)',
        AVG(TIME) as 'Avg Query Time (sec)'
    FROM information_schema.processlist
    WHERE COMMAND NOT IN ('Sleep', 'Connect');" "QUERY ACTIVITY"

    # InnoDB status
    run_query "
    SELECT
        'Buffer Pool Hit Rate (%)' as Metric,
        ROUND(VARIABLE_VALUE, 2) as Value,
        CASE
            WHEN CAST(VARIABLE_VALUE AS DECIMAL) > 95 THEN '✅ EXCELLENT'
            WHEN CAST(VARIABLE_VALUE AS DECIMAL) > 90 THEN '⚠️  GOOD'
            ELSE '❌ POOR'
        END as Status
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME = 'Innodb_buffer_pool_hit_rate'
    UNION ALL
    SELECT
        'Lock Waits',
        COUNT(*),
        CASE WHEN COUNT(*) > 0 THEN '⚠️  ACTIVE WAITS' ELSE '✅ NO WAITS' END
    FROM information_schema.innodb_lock_waits;" "INNODB PERFORMANCE"
}

# Monitor system resources
monitor_resources() {
    log "Monitoring System Resources..."

    run_query "
    SELECT
        'InnoDB Buffer Pool (MB)' as Resource,
        ROUND(@@innodb_buffer_pool_size / 1024 / 1024, 0) as Allocated
    UNION ALL
    SELECT
        'Current Memory Usage (MB)',
        ROUND((SELECT SUM(current_alloc)
               FROM sys.memory_by_thread_by_current_bytes
               WHERE thread_id IN (
                   SELECT thread_id
                   FROM performance_schema.threads
                   WHERE PROCESSLIST_STATE IS NOT NULL
               )) / 1024 / 1024, 0);" "MEMORY USAGE"

    run_query "
    SELECT
        VARIABLE_NAME as 'I/O Metric',
        VARIABLE_VALUE as 'Value'
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN (
        'Innodb_data_reads',
        'Innodb_data_writes',
        'Innodb_data_read',
        'Innodb_data_written'
    );" "I/O STATISTICS"
}

# Monitor PVC storage (Kubernetes environments)
monitor_storage() {
    # Check if kubectl is available and we're in a K8s environment
    if ! command -v kubectl &> /dev/null; then
        return 0  # Skip silently if not in K8s
    fi

    # Try to detect namespace from MySQL host if it contains a service name
    local namespace=""
    if [[ "$MYSQL_HOST" =~ ^[^.]+\. ]]; then
        # Extract namespace from service FQDN (e.g., mysql.default.svc.cluster.local)
        namespace=$(echo "$MYSQL_HOST" | cut -d. -f2)
    fi
    
    # If no namespace detected, try common ones or get from context
    if [ -z "$namespace" ]; then
        namespace=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "default")
    fi

    log "Monitoring Storage (PVCs in namespace: $namespace)..."

    # Get PVC information for the namespace
    local pvc_output
    if pvc_output=$(kubectl get pvc -n "$namespace" --no-headers 2>/dev/null); then
        if [ -n "$pvc_output" ]; then
            echo "=== PERSISTENT VOLUME CLAIMS (PVCs) ==="
            printf "%-40s %-10s %-12s %-12s %-8s\n" "NAME" "STATUS" "CAPACITY" "USED" "AVAIL%"
            echo "------------------------------------------------------------------------------------"
            
            while IFS= read -r line; do
                local pvc_name=$(echo "$line" | awk '{print $1}')
                local status=$(echo "$line" | awk '{print $2}')
                local capacity=$(echo "$line" | awk '{print $4}')
                
                # Try to get actual usage from the pod mounting this PVC
                local pod_name=""
                if command -v jq &> /dev/null; then
                    pod_name=$(kubectl get pods -n "$namespace" -o json 2>/dev/null | \
                        jq -r --arg pvc "$pvc_name" '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | .metadata.name' 2>/dev/null | head -1)
                fi
                
                local usage="N/A"
                local avail_pct="N/A"
                local avail_pct_colored="N/A"
                
                if [ -n "$pod_name" ] && kubectl get pod "$pod_name" -n "$namespace" &>/dev/null 2>&1; then
                    # Find the mount point for this PVC
                    local mount_point=""
                    if command -v jq &> /dev/null; then
                        mount_point=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | \
                            jq -r --arg pvc "$pvc_name" '.spec.volumes[] | select(.persistentVolumeClaim.claimName == $pvc) | .name' 2>/dev/null | head -1)
                    fi
                    
                    if [ -n "$mount_point" ]; then
                        # Get the actual mount path from container
                        local container_path=""
                        if command -v jq &> /dev/null; then
                            container_path=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | \
                                jq -r --arg vol "$mount_point" '.spec.containers[0].volumeMounts[] | select(.name == $vol) | .mountPath' 2>/dev/null | head -1)
                        fi
                        
                        if [ -n "$container_path" ]; then
                            # Get disk usage from the pod
                            local df_output
                            df_output=$(kubectl exec "$pod_name" -n "$namespace" -- df -h "$container_path" 2>/dev/null | tail -1)
                            if [ $? -eq 0 ] && [ -n "$df_output" ]; then
                                usage=$(echo "$df_output" | awk '{print $3}')
                                avail_pct=$(echo "$df_output" | awk '{print $5}' | tr -d '%')
                                
                                # Color code based on usage
                                if [ "$avail_pct" != "N/A" ] && [ -n "$avail_pct" ]; then
                                    if [ "$avail_pct" -gt 90 ] 2>/dev/null; then
                                        avail_pct_colored="${RED}${avail_pct}%${NC}"
                                    elif [ "$avail_pct" -gt 75 ] 2>/dev/null; then
                                        avail_pct_colored="${YELLOW}${avail_pct}%${NC}"
                                    else
                                        avail_pct_colored="${GREEN}${avail_pct}%${NC}"
                                    fi
                                else
                                    avail_pct_colored="N/A"
                                fi
                            fi
                        fi
                    fi
                fi
                
                # Use echo with -e to properly render color codes
                echo -e "$(printf "%-40s %-10s %-12s %-12s" "$pvc_name" "$status" "$capacity" "$usage") $avail_pct_colored"
            done <<< "$pvc_output"
            echo
            
            # Summary of storage class usage
            echo "=== STORAGE CLASS USAGE ==="
            kubectl get pvc -n "$namespace" --no-headers 2>/dev/null | awk '{print $6}' | sort | uniq -c | \
                awk '{printf "%-40s %s PVCs\n", $2, $1}'
            echo
        else
            info "No PVCs found in namespace: $namespace"
        fi
    fi
}

# Monitor storage in detail for report
monitor_storage_detailed() {
    if ! command -v kubectl &> /dev/null; then
        return 0
    fi

    local namespace=""
    if [[ "$MYSQL_HOST" =~ ^[^.]+\. ]]; then
        namespace=$(echo "$MYSQL_HOST" | cut -d. -f2)
    fi
    
    if [ -z "$namespace" ]; then
        namespace=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "default")
    fi

    echo "================================================================="
    echo "STORAGE DETAILS (Namespace: $namespace)"
    echo "================================================================="
    
    kubectl get pvc -n "$namespace" -o wide 2>/dev/null || echo "No PVC information available"
    echo
    
    echo "PVC to Pod Mappings:"
    if command -v jq &> /dev/null; then
        kubectl get pods -n "$namespace" -o json 2>/dev/null | \
            jq -r '.items[] | "\(.metadata.name): " + ([.spec.volumes[]?.persistentVolumeClaim.claimName] | map(select(. != null)) | join(", "))' 2>/dev/null | \
            grep -v ": $" || echo "No pods with PVCs found"
    else
        echo "(jq not installed - install with: sudo apt-get install jq)"
    fi
    echo
}

# Generate summary report
generate_report() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local report_file="$OUTPUT_DIR/pxc-load-test-report-$timestamp.txt"

    log "Generating comprehensive report: $report_file"

    {
        echo "================================================================="
        echo "PXC LOAD TESTING REPORT - $(date)"
        echo "================================================================="
        echo
        echo "CLUSTER CONFIGURATION:"
        echo "Host: $MYSQL_HOST:$MYSQL_PORT"
        echo "User: $MYSQL_USER"
        echo "Monitoring Interval: $INTERVAL seconds"
        echo

        mysql $MYSQL_OPTS -e "
        SELECT
            'MySQL Version' as Config,
            VERSION() as Value
        UNION ALL
        SELECT
            'PXC Version',
            (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_provider_version')
        UNION ALL
        SELECT
            'Cluster Name',
            VARIABLE_VALUE
        FROM performance_schema.global_variables
        WHERE VARIABLE_NAME = 'wsrep_cluster_name'
        UNION ALL
        SELECT
            'Node Name',
            VARIABLE_VALUE
        FROM performance_schema.global_variables
        WHERE VARIABLE_NAME = 'wsrep_node_name';"

        echo
        echo "================================================================="
        echo "CLUSTER HEALTH SUMMARY"
        echo "================================================================="

        mysql $MYSQL_OPTS -e "
        SELECT
            'Cluster Size' as Metric,
            VARIABLE_VALUE as Value
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'wsrep_cluster_size'
        UNION ALL
        SELECT
            'Cluster Status',
            VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'wsrep_cluster_status'
        UNION ALL
        SELECT
            'Flow Control Paused Time',
            VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'wsrep_flow_control_paused'
        UNION ALL
        SELECT
            'Certification Failures',
            VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'wsrep_cert_failures';"

        echo
        echo "================================================================="
        echo "PERFORMANCE SUMMARY"
        echo "================================================================="

        mysql $MYSQL_OPTS -e "
        SELECT
            'Max Connections' as Metric,
            @@max_connections as Value
        UNION ALL
        SELECT
            'Current Connections',
            COUNT(*)
        FROM information_schema.processlist
        UNION ALL
        SELECT
            'Active Queries',
            COUNT(*)
        FROM information_schema.processlist
        WHERE COMMAND NOT IN ('Sleep', 'Connect')
        UNION ALL
        SELECT
            'Buffer Pool Hit Rate (%)',
            ROUND(VARIABLE_VALUE, 2)
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'Innodb_buffer_pool_hit_rate'
        UNION ALL
        SELECT
            'Lock Waits',
            COUNT(*)
        FROM information_schema.innodb_lock_waits;"

        echo
        monitor_storage_detailed

    } > "$report_file" 2>/dev/null || warning "Some queries failed during report generation"

    info "Report saved to: $report_file"
}

# Main monitoring loop
main() {
    info "Starting PXC Load Testing Monitor"
    info "Host: $MYSQL_HOST:$MYSQL_PORT"
    info "Interval: $INTERVAL seconds"
    info "Output directory: $OUTPUT_DIR"
    echo

    check_mysql_client
    check_mysql_connection

    log "Initial cluster health check..."
    monitor_cluster_status
    monitor_performance
    monitor_resources
    monitor_storage

    if [ "$INTERVAL" -gt 0 ]; then
        info "Starting continuous monitoring (Ctrl+C to stop)..."
        echo "Press Ctrl+C to stop monitoring and generate final report"
        echo

        trap 'echo; log "Stopping monitoring..."; generate_report; exit 0' INT

        while true; do
            sleep "$INTERVAL"
            echo "================================================================="
            monitor_cluster_status
            monitor_performance
            monitor_resources
            monitor_storage
            echo "================================================================="
        done
    else
        log "Single monitoring run completed"
        generate_report
    fi
}

# Help function
show_help() {
    cat << EOF
PXC Load Testing Monitor

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --host HOST          MySQL host (default: 127.0.0.1)
    -P, --port PORT          MySQL port (default: 3306)
    -u, --user USER          MySQL user (default: root)
    -p [PASS]                MySQL password (prompts if not provided)
                               Use: -p (prompt), -pPASS (no space), or -p PASS
    --password PASS          MySQL password (required argument)
    -i, --interval SEC       Monitoring interval in seconds (default: 5)
                               Use 0 for single run only
    -o, --output DIR         Output directory (default: auto-generated)
    --help                   Show this help

ENVIRONMENT VARIABLES:
    MYSQL_HOST               Same as --host
    MYSQL_PORT               Same as --port
    MYSQL_USER               Same as --user
    MYSQL_PASSWORD           Same as --password
    INTERVAL                 Same as --interval
    OUTPUT_DIR               Same as --output

FEATURES:
    - Real-time cluster health monitoring
    - Performance metrics tracking
    - Resource usage monitoring
    - PVC storage monitoring (Kubernetes environments)
    - Daemon mode with configurable refresh interval
    - Comprehensive final report generation

EXAMPLES:
    # Monitor every 5 seconds - prompt for password
    $0 -h 2.3.4.5 -u root -p

    # Provide password directly (with space)
    $0 -h 2.3.4.5 -u root -p mypassword

    # Provide password directly (no space, MySQL style)
    $0 -h 2.3.4.5 -u root -pmypassword

    # Single report only
    $0 -i 0 -u admin -p

    # Custom host and port with password prompt
    $0 -h mysql-cluster.example.com -P 3307 -u admin -p

    # On-prem with local MySQL
    $0 -h 127.0.0.1 -u root -p

KUBERNETES ENVIRONMENTS:
    When running in Kubernetes (kubectl available), the script will
    automatically detect and monitor PVC storage usage for the MySQL
    pods, including:
    - PVC capacity and status
    - Actual disk usage per PVC
    - Storage class information
    - PVC to Pod mappings

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            if [ $# -lt 2 ]; then
                error "Option $1 requires an argument"
                exit 1
            fi
            MYSQL_HOST="$2"
            shift 2
            ;;
        -P|--port)
            if [ $# -lt 2 ]; then
                error "Option $1 requires an argument"
                exit 1
            fi
            MYSQL_PORT="$2"
            shift 2
            ;;
        -u|--user)
            if [ $# -lt 2 ]; then
                error "Option $1 requires an argument"
                exit 1
            fi
            MYSQL_USER="$2"
            shift 2
            ;;
        -p*)
            # Support both -p (prompt), -pPASSWORD (no space), and -p PASSWORD (with space)
            if [ "$1" = "-p" ] || [ "$1" = "--password" ]; then
                # Check if next argument exists and doesn't start with -
                if [ $# -gt 1 ] && [[ ! "$2" =~ ^- ]]; then
                    MYSQL_PASSWORD="$2"
                    shift 2
                else
                    # Prompt for password
                    MYSQL_PASSWORD="__PROMPT__"
                    shift
                fi
            else
                # Handle -pPASSWORD format (no space)
                MYSQL_PASSWORD="${1#-p}"
                shift
            fi
            ;;
        --password)
            if [ $# -lt 2 ]; then
                error "Option $1 requires an argument"
                exit 1
            fi
            MYSQL_PASSWORD="$2"
            shift 2
            ;;
        -i|--interval)
            if [ $# -lt 2 ]; then
                error "Option $1 requires an argument"
                exit 1
            fi
            INTERVAL="$2"
            shift 2
            ;;
        -o|--output)
            if [ $# -lt 2 ]; then
                error "Option $1 requires an argument"
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Password prompt if not provided or explicitly requested
if [ -z "$MYSQL_PASSWORD" ] || [ "$MYSQL_PASSWORD" = "__PROMPT__" ]; then
    read -s -p "Enter MySQL password for $MYSQL_USER: " MYSQL_PASSWORD
    echo
    if [ -z "$MYSQL_PASSWORD" ]; then
        warning "No password provided, attempting to connect without password"
    fi
fi

main

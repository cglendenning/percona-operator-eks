#!/bin/bash
# Percona XtraDB Cluster Load Testing Monitor
# Run this script during load testing to monitor cluster health

# Note: We don't use 'set -e' here to allow better error handling
set -uo pipefail

# Configuration
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
INTERVAL="${INTERVAL:-5}"  # seconds between checks
DASHBOARD_MODE="${DASHBOARD_MODE:-1}"  # 1 for dashboard mode, 0 for scrolling mode
SAVE_REPORTS="${SAVE_REPORTS:-0}"  # Only create output dir if explicitly requested

# Get terminal dimensions
get_terminal_width() {
    tput cols 2>/dev/null || echo 80
}

get_terminal_height() {
    tput lines 2>/dev/null || echo 24
}

TERM_WIDTH=$(get_terminal_width)
TERM_HEIGHT=$(get_terminal_height)

# Dashboard state - line numbers for each value
declare -A VALUE_POSITIONS

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Terminal control sequences
CURSOR_HIDE='\033[?25l'
CURSOR_SHOW='\033[?25h'
CLEAR_LINE='\033[K'

# Create output directory only if reports are enabled
if [ "$SAVE_REPORTS" = "1" ]; then
    OUTPUT_DIR="${OUTPUT_DIR:-pxc-monitoring-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$OUTPUT_DIR"
fi

# MySQL connection options (will be updated after password prompt)
build_mysql_opts() {
    MYSQL_OPTS="-h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER"
    if [ -n "$MYSQL_PASSWORD" ]; then
        MYSQL_OPTS="$MYSQL_OPTS -p$MYSQL_PASSWORD"
    fi
}

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
    info "Checking for MySQL client..."
    if ! command -v mysql &> /dev/null; then
        echo ""
        error "MySQL client (mysql command) is not installed or not in PATH"
        error ""
        error "Installation instructions:"
        error "  Ubuntu/Debian/WSL: sudo apt-get update && sudo apt-get install mysql-client"
        error "  RHEL/CentOS:       sudo yum install mysql"
        error "  macOS:             brew install mysql-client"
        error ""
        error "After installation, verify with: mysql --version"
        echo ""
        exit 1
    fi
    
    local mysql_version
    mysql_version=$(mysql --version 2>/dev/null || echo "unknown")
    info "✓ MySQL client found: $mysql_version"
}

check_mysql_connection() {
    info "Testing MySQL connection to $MYSQL_HOST:$MYSQL_PORT..."
    
    local error_output
    local exit_code
    
    # Try to connect - capture both stdout and stderr
    error_output=$(mysql $MYSQL_OPTS -e "SELECT 1;" 2>&1)
    exit_code=$?
    
    if [ "${DEBUG:-0}" = "1" ]; then
        info "MySQL exit code: $exit_code"
        if [ -n "$error_output" ]; then
            info "MySQL output: $error_output"
        fi
    fi
    
    if [ $exit_code -ne 0 ]; then
        echo ""
        error "Cannot connect to MySQL at $MYSQL_HOST:$MYSQL_PORT"
        error "Exit code: $exit_code"
        error ""
        error "MySQL error message:"
        echo "$error_output" | while IFS= read -r line; do
            error "  $line"
        done
        error ""
        error "Connection details:"
        error "  Host: $MYSQL_HOST"
        error "  Port: $MYSQL_PORT"
        error "  User: $MYSQL_USER"
        error "  Password: $([ -n "$MYSQL_PASSWORD" ] && echo "[SET]" || echo "[NOT SET]")"
        error ""
        error "Troubleshooting steps:"
        error "  1. Test connectivity: nc -zv $MYSQL_HOST $MYSQL_PORT"
        error "  2. Try manual connection: mysql -h $MYSQL_HOST -P $MYSQL_PORT -u $MYSQL_USER -p"
        error "  3. Verify credentials are correct"
        error "  4. Check if MySQL accepts remote connections (bind-address in my.cnf)"
        error "  5. Check firewall rules on both client and server"
        echo ""
        exit 1
    fi
    
    info "✓ MySQL connection successful"
}

# Run a query and return result (for dashboard mode)
run_query_silent() {
    local query="$1"
    mysql $MYSQL_OPTS -e "$query" 2>/dev/null || echo ""
}

# Run a query and format output (for scrolling mode)
run_query() {
    local query="$1"
    local title="$2"

    echo "=== $title ==="
    if ! mysql $MYSQL_OPTS -e "$query" 2>/dev/null; then
        echo "Query failed or no data"
    fi
    echo
}

# Fetch all metrics at once
fetch_all_metrics() {
    # Fetch cluster metrics
    CLUSTER_SIZE=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_cluster_size';" 2>/dev/null || echo "N/A")
    CLUSTER_STATUS=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_cluster_status';" 2>/dev/null || echo "N/A")
    NODE_READY=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_ready';" 2>/dev/null || echo "N/A")
    FLOW_CONTROL=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_flow_control_paused';" 2>/dev/null || echo "N/A")
    
    # Fetch queue metrics
    RECV_QUEUE=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_local_recv_queue';" 2>/dev/null || echo "N/A")
    SEND_QUEUE=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'wsrep_local_send_queue';" 2>/dev/null || echo "N/A")
    
    # Fetch connection metrics
    CURRENT_CONNS=$(mysql $MYSQL_OPTS -sN -e "SELECT COUNT(*) FROM information_schema.processlist;" 2>/dev/null || echo "N/A")
    MAX_CONNS=$(mysql $MYSQL_OPTS -sN -e "SELECT @@max_connections;" 2>/dev/null || echo "N/A")
    ACTIVE_THREADS=$(mysql $MYSQL_OPTS -sN -e "SELECT COUNT(*) FROM performance_schema.threads WHERE PROCESSLIST_STATE IS NOT NULL;" 2>/dev/null || echo "N/A")
    
    # Fetch query metrics
    RUNNING_QUERIES=$(mysql $MYSQL_OPTS -sN -e "SELECT COUNT(*) FROM information_schema.processlist WHERE COMMAND NOT IN ('Sleep', 'Connect');" 2>/dev/null || echo "N/A")
    
    # Fetch InnoDB metrics
    BP_READS=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads';" 2>/dev/null || echo "0")
    BP_READ_REQS=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests';" 2>/dev/null || echo "1")
    if [ "$BP_READ_REQS" != "0" ] && [ "$BP_READ_REQS" != "N/A" ]; then
        BP_HIT_RATE=$(awk "BEGIN {printf \"%.2f\", 100.0 * (1.0 - ($BP_READS / $BP_READ_REQS))}")
    else
        BP_HIT_RATE="N/A"
    fi
    
    # Fetch I/O metrics
    INNODB_DATA_READ=$(mysql $MYSQL_OPTS -sN -e "SELECT ROUND(VARIABLE_VALUE / 1024 / 1024, 2) FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_data_read';" 2>/dev/null || echo "N/A")
    INNODB_DATA_WRITTEN=$(mysql $MYSQL_OPTS -sN -e "SELECT ROUND(VARIABLE_VALUE / 1024 / 1024, 2) FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_data_written';" 2>/dev/null || echo "N/A")
    INNODB_DATA_READS=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_data_reads';" 2>/dev/null || echo "N/A")
    INNODB_DATA_WRITES=$(mysql $MYSQL_OPTS -sN -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_data_writes';" 2>/dev/null || echo "N/A")
    
    # Fetch buffer pool size
    BUFFER_POOL_SIZE=$(mysql $MYSQL_OPTS -sN -e "SELECT ROUND(@@innodb_buffer_pool_size / 1024 / 1024, 0);" 2>/dev/null || echo "N/A")
}

# Terminal cursor control
cursor_to() {
    local row=$1
    local col=${2:-1}
    printf '\033[%d;%dH' "$row" "$col"
}

save_cursor() {
    printf '\033[s'
}

restore_cursor() {
    printf '\033[u'
}

clear_to_eol() {
    printf '\033[K'
}

hide_cursor() {
    printf '\033[?25l'
}

show_cursor() {
    printf '\033[?25h'
}

# Print a horizontal separator line
print_separator() {
    local char="${1:--}"
    printf '%*s\n' "$TERM_WIDTH" '' | tr ' ' "$char"
}

# Print centered text (without newline, for use in bordered layouts)
print_centered() {
    local text="$1"
    # Remove color codes for length calculation
    local clean_text=$(echo -e "$text" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
    local text_len=${#clean_text}
    local width=170  # Dashboard width
    local padding=$(( (width - text_len - 2) / 2 ))  # -2 for borders
    printf '%*s%s%*s' $padding '' "$text" $((width - text_len - padding - 2)) ''
}

# Update a value at a specific position
update_value_at() {
    local row=$1
    local col=$2
    local value="$3"
    save_cursor
    cursor_to "$row" "$col"
    clear_to_eol
    echo -ne "$value"
    restore_cursor
}

# Draw the static dashboard layout (once)
draw_dashboard_layout() {
    clear
    hide_cursor
    
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}$(print_centered "PERCONA XtraDB CLUSTER MONITORING DASHBOARD")${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}$(print_centered "$MYSQL_HOST:$MYSQL_PORT | User: $MYSQL_USER")${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Cluster Health Section
    echo -e "${BOLD}║ CLUSTER HEALTH${NC}                                ${BOLD}║ REPLICATION QUEUES${NC}                     ${BOLD}║ CONNECTIONS${NC}                                  ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo    "║ Cluster Size:                                 ║ Local Recv Queue:                      ║ Current:                                       ║"
    echo    "║ Cluster Status:                               ║ Local Send Queue:                      ║ Max:                                           ║"
    echo    "║ Node Ready:                                   ║                                        ║ Active Threads:                                ║"
    echo    "║ Flow Control Paused:                          ║                                        ║ Running Queries:                               ║"
    
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║ INNODB PERFORMANCE${NC}                           ${BOLD}║ I/O STATISTICS${NC}                                                                                   ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo    "║ Buffer Pool Size (MB):                        ║ Data Read (MB):                              Data Written (MB):                              ║"
    echo    "║ Buffer Pool Hit Rate (%):                     ║ Read Operations:                             Write Operations:                               ║"
    
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC} Last Update: $timestamp                                                                                Press Ctrl+C to exit ${BOLD}║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    # Store value positions (row, column)
    VALUE_POSITIONS[CLUSTER_SIZE]="7,20"
    VALUE_POSITIONS[RECV_QUEUE]="7,72"
    VALUE_POSITIONS[CURRENT_CONNS]="7,124"
    VALUE_POSITIONS[CLUSTER_STATUS]="8,21"
    VALUE_POSITIONS[SEND_QUEUE]="8,72"
    VALUE_POSITIONS[MAX_CONNS]="8,124"
    VALUE_POSITIONS[NODE_READY]="9,18"
    VALUE_POSITIONS[ACTIVE_THREADS]="9,124"
    VALUE_POSITIONS[FLOW_CONTROL]="10,26"
    VALUE_POSITIONS[RUNNING_QUERIES]="10,124"
    
    VALUE_POSITIONS[BUFFER_POOL_SIZE]="14,28"
    VALUE_POSITIONS[INNODB_DATA_READ]="14,72"
    VALUE_POSITIONS[INNODB_DATA_WRITTEN]="14,114"
    VALUE_POSITIONS[BP_HIT_RATE]="15,31"
    VALUE_POSITIONS[INNODB_DATA_READS]="15,72"
    VALUE_POSITIONS[INNODB_DATA_WRITES]="15,114"
    
    VALUE_POSITIONS[TIMESTAMP]="18,18"
}

# Update dashboard values
update_dashboard_values() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Update cluster health values
    update_value_at 7 20 "$(format_value "$CLUSTER_SIZE" "3")"
    update_value_at 8 21 "$(format_value "$CLUSTER_STATUS" "Primary")"
    update_value_at 9 18 "$(format_value "$NODE_READY" "ON")"
    update_value_at 10 26 "$(format_value "$FLOW_CONTROL" "0")"
    
    # Update queue values
    update_value_at 7 72 "$(format_value "$RECV_QUEUE" "0")"
    update_value_at 8 72 "$(format_value "$SEND_QUEUE" "0")"
    
    # Update connection values
    update_value_at 7 124 "$CURRENT_CONNS / $MAX_CONNS      "
    update_value_at 8 124 "$MAX_CONNS      "
    update_value_at 9 124 "$ACTIVE_THREADS      "
    update_value_at 10 124 "$RUNNING_QUERIES      "
    
    # Update InnoDB values
    update_value_at 14 28 "$BUFFER_POOL_SIZE      "
    update_value_at 15 31 "$(format_value "$BP_HIT_RATE" "99+")"
    
    # Update I/O values
    update_value_at 14 72 "$INNODB_DATA_READ      "
    update_value_at 14 114 "$INNODB_DATA_WRITTEN      "
    update_value_at 15 72 "$INNODB_DATA_READS      "
    update_value_at 15 114 "$INNODB_DATA_WRITES      "
    
    # Update timestamp
    update_value_at 18 18 "$timestamp"
}

# Format and colorize a value based on expected good value
format_value() {
    local value="$1"
    local expected="$2"
    
    if [ "$value" = "N/A" ]; then
        echo -e "${YELLOW}N/A${NC}      "
    elif [ "$value" = "$expected" ]; then
        echo -e "${GREEN}${value}${NC}      "
    else
        echo -e "${YELLOW}${value}${NC}      "
    fi
}

# Monitor cluster status
monitor_cluster_status() {
    if [ "$DASHBOARD_MODE" != "1" ]; then
        log "Monitoring Cluster Status..."
    fi

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
    if [ "$DASHBOARD_MODE" != "1" ]; then
        log "Monitoring Performance Metrics..."
    fi

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

    # InnoDB status - calculate buffer pool hit rate manually if not available
    run_query "
    SELECT
        'Buffer Pool Hit Rate (%)' as Metric,
        ROUND(100.0 * (1.0 - (
            (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
            (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')
        )), 2) as Value,
        CASE
            WHEN (100.0 * (1.0 - (
                (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
                (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')
            ))) > 95 THEN '✅ EXCELLENT'
            WHEN (100.0 * (1.0 - (
                (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
                (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')
            ))) > 90 THEN '⚠️  GOOD'
            ELSE '❌ POOR'
        END as Status;" "INNODB PERFORMANCE"
}

# Monitor system resources
monitor_resources() {
    if [ "$DASHBOARD_MODE" != "1" ]; then
        log "Monitoring System Resources..."
    fi

    run_query "
    SELECT
        'InnoDB Buffer Pool (MB)' as Resource,
        ROUND(@@innodb_buffer_pool_size / 1024 / 1024, 0) as Allocated
    UNION ALL
    SELECT
        'Max Connections',
        @@max_connections
    UNION ALL
    SELECT
        'Current Connections',
        (SELECT COUNT(*) FROM information_schema.processlist);" "MEMORY & CONNECTIONS"

    run_query "
    SELECT
        VARIABLE_NAME as 'I/O Metric',
        ROUND(VARIABLE_VALUE / 1024 / 1024, 2) as 'Value (MB)'
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN (
        'Innodb_data_read',
        'Innodb_data_written'
    )
    UNION ALL
    SELECT
        VARIABLE_NAME,
        VARIABLE_VALUE
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN (
        'Innodb_data_reads',
        'Innodb_data_writes'
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
    # Check if host looks like a Kubernetes service (contains letters and dots, not just IP)
    if [[ "$MYSQL_HOST" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z] ]]; then
        # Extract namespace from service FQDN (e.g., mysql.default.svc.cluster.local)
        namespace=$(echo "$MYSQL_HOST" | cut -d. -f2)
    fi
    
    # If no namespace detected, try to get from context
    if [ -z "$namespace" ]; then
        namespace=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    fi
    
    # Default to "default" if still empty
    if [ -z "$namespace" ]; then
        namespace="default"
    fi

    if [ "$DASHBOARD_MODE" != "1" ]; then
        log "Monitoring Storage (PVCs in namespace: $namespace)..."
    fi

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
    if [ "$SAVE_REPORTS" = "1" ]; then
        info "Output directory: $OUTPUT_DIR"
    fi
    info "Dashboard mode: $([ "$DASHBOARD_MODE" = "1" ] && echo "enabled" || echo "disabled (scrolling)")"
    echo

    check_mysql_client
    check_mysql_connection

    if [ "$INTERVAL" -gt 0 ]; then
        if [ "$DASHBOARD_MODE" = "1" ]; then
            info "Starting dashboard monitoring (refreshing every $INTERVAL seconds)..."
            info "Press Ctrl+C to stop"
            sleep 2  # Give user time to read
            
            # Set up exit handler
            trap 'show_cursor; clear; echo; log "Monitoring stopped"; exit 0' INT TERM EXIT
            
            # Draw static layout once
            draw_dashboard_layout
            
            # Update loop - only values change
            while true; do
                fetch_all_metrics
                update_dashboard_values
                sleep "$INTERVAL"
            done
        else
            # Scrolling mode
            info "Starting continuous monitoring (Ctrl+C to stop)..."
            echo "Press Ctrl+C to stop monitoring"
            if [ "$SAVE_REPORTS" = "1" ]; then
                echo "Final report will be generated on exit"
            fi
            echo

            if [ "$SAVE_REPORTS" = "1" ]; then
                trap 'echo; log "Stopping monitoring..."; generate_report; exit 0' INT
            else
                trap 'echo; log "Monitoring stopped"; exit 0' INT
            fi

            while true; do
                echo "================================================================="
                monitor_cluster_status
                monitor_performance
                monitor_resources
                monitor_storage
                echo "================================================================="
                sleep "$INTERVAL"
            done
        fi
    else
        # Single run mode
        if [ "$DASHBOARD_MODE" = "1" ]; then
            draw_dashboard_layout
            fetch_all_metrics
            update_dashboard_values
            show_cursor
            echo ""
            echo ""
            read -p "Press Enter to exit..." -t 30
        else
            log "Single monitoring run"
            monitor_cluster_status
            monitor_performance
            monitor_resources
            monitor_storage
        fi
        
        if [ "$SAVE_REPORTS" = "1" ]; then
            generate_report
        fi
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
    -o, --output DIR         Output directory for reports (implies --save-reports)
    -s, --scroll             Disable dashboard mode (use scrolling output)
    -r, --save-reports       Save reports to disk (creates output directory)
    --help                   Show this help

ENVIRONMENT VARIABLES:
    MYSQL_HOST               Same as --host
    MYSQL_PORT               Same as --port
    MYSQL_USER               Same as --user
    MYSQL_PASSWORD           Same as --password
    INTERVAL                 Same as --interval
    OUTPUT_DIR               Output directory for reports
    SAVE_REPORTS             Set to 1 to save reports (default: 0)
    DASHBOARD_MODE           Set to 0 to disable dashboard (default: 1)
    DEBUG                    Set to 1 to enable debug output (default: 0)

FEATURES:
    - Real-time cluster health monitoring
    - Performance metrics tracking
    - Resource usage monitoring
    - PVC storage monitoring (Kubernetes environments)
    - Daemon mode with configurable refresh interval
    - Comprehensive final report generation

EXAMPLES:
    # Dashboard mode (default) - refreshing display, no files created
    $0 -h 2.3.4.5 -u root -p

    # Dashboard mode with report saving
    $0 -h 2.3.4.5 -u root -p --save-reports

    # Scrolling mode - old behavior
    $0 -h 2.3.4.5 -u root -p --scroll

    # Provide password directly (with space)
    $0 -h 2.3.4.5 -u root -p mypassword

    # Provide password directly (no space, MySQL style)
    $0 -h 2.3.4.5 -u root -pmypassword

    # Custom refresh interval (10 seconds)
    $0 -h mysql-cluster.example.com -P 3307 -u admin -p -i 10

    # Save reports to custom directory
    $0 -h 2.3.4.5 -u root -p -o /tmp/mysql-reports

    # On-prem with local MySQL
    $0 -h 127.0.0.1 -u root -p

    # Debug mode - shows detailed connection info
    DEBUG=1 $0 -h 2.3.4.5 -u root -p

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
            SAVE_REPORTS=1
            shift 2
            ;;
        -r|--save-reports)
            SAVE_REPORTS=1
            shift
            ;;
        -s|--scroll)
            DASHBOARD_MODE=0
            shift
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

# Build MySQL connection options after password is set
build_mysql_opts

# Enable debug mode if DEBUG=1 is set
if [ "${DEBUG:-0}" = "1" ]; then
    info "Debug mode enabled"
    info "MySQL Host: $MYSQL_HOST"
    info "MySQL Port: $MYSQL_PORT"
    info "MySQL User: $MYSQL_USER"
    info "Password set: $([ -n "$MYSQL_PASSWORD" ] && echo "yes" || echo "no")"
fi

main

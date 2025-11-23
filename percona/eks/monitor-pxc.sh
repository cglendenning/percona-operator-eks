#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# PXC Cluster Monitor - EKS Edition
#
# Monitors a Percona XtraDB Cluster (PXC) in real-time, displaying:
# - MySQL operations (SELECT/INSERT/UPDATE/DELETE per second)
# - Storage usage (data_dir percentage)
# - Memory pressure indicators
# - Binlog activity (PITR rate, binlog creation rate)
# - Async replication status (if configured)
#
# Works under WSL and macOS
#############################################################################

# Default values
NAMESPACE="${NAMESPACE:-percona}"
CLUSTER_NAME="${CLUSTER_NAME:-pxc-cluster}"
INTERVAL="${INTERVAL:-5}"
KUBECONFIG="${KUBECONFIG:-}"

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Monitor a Percona XtraDB Cluster in real-time

OPTIONS:
    -n, --namespace NAME        Kubernetes namespace (default: $NAMESPACE)
    -c, --cluster NAME          PXC cluster name (default: $CLUSTER_NAME)
    -i, --interval SECONDS      Refresh interval in seconds (default: $INTERVAL)
    --kubeconfig PATH           Path to kubeconfig file
    -h, --help                  Show this help message

ENVIRONMENT:
    NAMESPACE                   Default namespace
    CLUSTER_NAME                Default cluster name
    INTERVAL                    Default refresh interval
    KUBECONFIG                  Path to kubeconfig

EXAMPLES:
    # Monitor default cluster
    $0

    # Monitor specific cluster with 2-second refresh
    $0 -n pxc-prod -c my-cluster -i 2

    # Monitor with custom kubeconfig
    $0 --kubeconfig ~/.kube/prod-config
EOF
}

# Parse command line arguments
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
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Kubectl wrapper to handle KUBECONFIG
kctl() {
    if [ -n "${KUBECONFIG:-}" ]; then
        kubectl --kubeconfig="$KUBECONFIG" "$@"
    else
        kubectl "$@"
    fi
}

# Clear screen for different platforms
clear_screen() {
    if command -v clear &> /dev/null; then
        clear
    else
        printf "\033c"
    fi
}

# Get PXC pods
get_pxc_pods() {
    kctl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=percona-xtradb-cluster,app.kubernetes.io/instance="$CLUSTER_NAME",app.kubernetes.io/component=pxc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""
}

# Get root password from secret
get_root_password() {
    local secret_name="$1"
    kctl get secret -n "$NAMESPACE" "$secret_name" -o jsonpath='{.data.root}' 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# Execute MySQL query
mysql_query() {
    local pod="$1"
    local password="$2"
    local query="$3"
    
    kctl exec -n "$NAMESPACE" "$pod" -c pxc -- mysql -uroot -p"$password" -sN -e "$query" 2>/dev/null || echo ""
}

# Get MySQL status variable
get_mysql_status() {
    local pod="$1"
    local password="$2"
    local variable="$3"
    
    mysql_query "$pod" "$password" "SHOW GLOBAL STATUS LIKE '$variable'" | awk '{print $2}'
}

# Get storage usage
get_storage_usage() {
    local pod="$1"
    
    kctl exec -n "$NAMESPACE" "$pod" -c pxc -- df -h /var/lib/mysql 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0"
}

# Get pod memory usage
get_memory_usage() {
    local pod="$1"
    
    # Get memory metrics from kubectl top
    local mem_usage=$(kctl top pod -n "$NAMESPACE" "$pod" --no-headers 2>/dev/null | awk '{print $3}' || echo "N/A")
    echo "$mem_usage"
}

# Get node zone (EKS-specific)
get_node_zone() {
    local pod="$1"
    
    local node=$(kctl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [ -n "$node" ]; then
        local zone=$(kctl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)
        echo "$zone"
    else
        echo "N/A"
    fi
}

# Get binlog info
get_binlog_info() {
    local pod="$1"
    local password="$2"
    
    # Get current binlog file and position
    local binlog_info=$(mysql_query "$pod" "$password" "SHOW MASTER STATUS" | head -1)
    local binlog_file=$(echo "$binlog_info" | awk '{print $1}')
    local binlog_pos=$(echo "$binlog_info" | awk '{print $2}')
    
    echo "${binlog_file}:${binlog_pos}"
}

# Get PITR status
get_pitr_status() {
    local pod="$1"
    local password="$2"
    
    # Check if PITR is enabled by looking at wsrep variables
    local pitr_enabled=$(mysql_query "$pod" "$password" "SELECT @@global.log_bin" | head -1)
    echo "$pitr_enabled"
}

# Get async replication status
get_async_replication_status() {
    local pod="$1"
    local password="$2"
    
    # Check if this node is a replica
    local replica_status=$(mysql_query "$pod" "$password" "SHOW SLAVE STATUS" 2>/dev/null)
    if [ -n "$replica_status" ]; then
        local io_running=$(echo "$replica_status" | grep "Slave_IO_Running" | awk '{print $2}')
        local sql_running=$(echo "$replica_status" | grep "Slave_SQL_Running" | awk '{print $2}')
        local seconds_behind=$(echo "$replica_status" | grep "Seconds_Behind_Master" | awk '{print $2}')
        echo "Replica|IO:${io_running}|SQL:${sql_running}|Lag:${seconds_behind}s"
    else
        # Check if this node is a source
        local replicas=$(mysql_query "$pod" "$password" "SHOW SLAVE HOSTS" | wc -l)
        if [ "$replicas" -gt 0 ]; then
            echo "Source|Replicas:${replicas}"
        else
            echo "None"
        fi
    fi
}

# Calculate rate
calculate_rate() {
    local current="$1"
    local previous="$2"
    local interval="$3"
    
    if [ -z "$previous" ] || [ "$previous" = "N/A" ]; then
        echo "0"
        return
    fi
    
    local diff=$((current - previous))
    if [ $diff -lt 0 ]; then
        # Counter wrapped or reset
        echo "0"
        return
    fi
    
    local rate=$(awk "BEGIN {printf \"%.2f\", $diff / $interval}")
    echo "$rate"
}

# Main monitoring loop
monitor_cluster() {
    # Find secret name
    local secret_name="${CLUSTER_NAME}-secrets"
    
    # Check if cluster exists
    local pods=$(get_pxc_pods)
    if [ -z "$pods" ]; then
        echo -e "${RED}Error: No PXC pods found for cluster '$CLUSTER_NAME' in namespace '$NAMESPACE'${NC}"
        echo "Please check cluster name and namespace."
        exit 1
    fi
    
    # Get root password
    local root_password=$(get_root_password "$secret_name")
    if [ -z "$root_password" ]; then
        echo -e "${RED}Error: Could not retrieve root password from secret '$secret_name'${NC}"
        exit 1
    fi
    
    # Storage for previous values (for rate calculation)
    declare -A prev_selects
    declare -A prev_inserts
    declare -A prev_updates
    declare -A prev_deletes
    declare -A prev_binlog_pos
    
    echo -e "${GREEN}Starting PXC Monitor for cluster: ${BOLD}$CLUSTER_NAME${NC}${GREEN} in namespace: ${BOLD}$NAMESPACE${NC}"
    echo -e "${CYAN}Press Ctrl+C to exit${NC}"
    sleep 2
    
    while true; do
        clear_screen
        
        # Header
        echo -e "${BOLD}${WHITE}╔════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${WHITE}║${NC}  ${CYAN}PXC Cluster Monitor - EKS${NC}                                                             ${BOLD}${WHITE}║${NC}"
        echo -e "${BOLD}${WHITE}╠════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
        printf "${BOLD}${WHITE}║${NC}  Cluster: ${BOLD}%-20s${NC} Namespace: ${BOLD}%-20s${NC} Interval: ${BOLD}%ds${NC}      ${BOLD}${WHITE}║${NC}\n" "$CLUSTER_NAME" "$NAMESPACE" "$INTERVAL"
        printf "${BOLD}${WHITE}║${NC}  Time: ${BOLD}%-30s${NC}                                                ${BOLD}${WHITE}║${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "${BOLD}${WHITE}╚════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # Monitor each pod
        for pod in $pods; do
            local zone=$(get_node_zone "$pod")
            echo -e "${BOLD}${BLUE}┌─ Pod: $pod ${WHITE}(Zone: $zone)${NC}"
            
            # Get current metrics
            local com_select=$(get_mysql_status "$pod" "$root_password" "Com_select")
            local com_insert=$(get_mysql_status "$pod" "$root_password" "Com_insert")
            local com_update=$(get_mysql_status "$pod" "$root_password" "Com_update")
            local com_delete=$(get_mysql_status "$pod" "$root_password" "Com_delete")
            
            # Calculate rates
            local select_rate=$(calculate_rate "$com_select" "${prev_selects[$pod]:-0}" "$INTERVAL")
            local insert_rate=$(calculate_rate "$com_insert" "${prev_inserts[$pod]:-0}" "$INTERVAL")
            local update_rate=$(calculate_rate "$com_update" "${prev_updates[$pod]:-0}" "$INTERVAL")
            local delete_rate=$(calculate_rate "$com_delete" "${prev_deletes[$pod]:-0}" "$INTERVAL")
            
            # Store current values for next iteration
            prev_selects[$pod]=$com_select
            prev_inserts[$pod]=$com_insert
            prev_updates[$pod]=$com_update
            prev_deletes[$pod]=$com_delete
            
            # MySQL Operations
            echo -e "${CYAN}├─ MySQL Operations (per second):${NC}"
            printf "│  ${GREEN}SELECT:${NC} %-10s ${YELLOW}INSERT:${NC} %-10s ${MAGENTA}UPDATE:${NC} %-10s ${RED}DELETE:${NC} %-10s\n" \
                "$select_rate" "$insert_rate" "$update_rate" "$delete_rate"
            
            # Storage (EKS uses EBS volumes)
            local storage_pct=$(get_storage_usage "$pod")
            local storage_color="${GREEN}"
            if [ "$storage_pct" -gt 80 ]; then
                storage_color="${RED}"
            elif [ "$storage_pct" -gt 60 ]; then
                storage_color="${YELLOW}"
            fi
            echo -e "${CYAN}├─ Storage (EBS):${NC}"
            printf "│  Data Directory: ${storage_color}%s%%${NC} used\n" "$storage_pct"
            
            # Memory
            local mem_usage=$(get_memory_usage "$pod")
            echo -e "${CYAN}├─ Memory:${NC}"
            printf "│  Usage: ${GREEN}%s${NC}\n" "$mem_usage"
            
            # Binlog Info
            local binlog_info=$(get_binlog_info "$pod" "$root_password")
            local binlog_file=$(echo "$binlog_info" | cut -d: -f1)
            local binlog_pos=$(echo "$binlog_info" | cut -d: -f2)
            
            # Calculate binlog rate
            local prev_pos="${prev_binlog_pos[$pod]:-0}"
            local binlog_rate=0
            if [ -n "$binlog_pos" ] && [ "$binlog_pos" != "N/A" ] && [ "$prev_pos" -gt 0 ]; then
                binlog_rate=$(calculate_rate "$binlog_pos" "$prev_pos" "$INTERVAL")
            fi
            prev_binlog_pos[$pod]=$binlog_pos
            
            echo -e "${CYAN}├─ Binlog:${NC}"
            printf "│  Current: ${BOLD}%s${NC} Position: ${BOLD}%s${NC}\n" "$binlog_file" "$binlog_pos"
            printf "│  Write Rate: ${GREEN}%.2f bytes/sec${NC}\n" "$binlog_rate"
            
            # PITR Status
            local pitr_enabled=$(get_pitr_status "$pod" "$root_password")
            local pitr_status="${RED}Disabled${NC}"
            if [ "$pitr_enabled" = "1" ]; then
                pitr_status="${GREEN}Enabled${NC}"
            fi
            printf "│  PITR: %b\n" "$pitr_status"
            
            # Async Replication
            local async_status=$(get_async_replication_status "$pod" "$root_password")
            echo -e "${CYAN}├─ Async Replication:${NC}"
            if [ "$async_status" = "None" ]; then
                echo -e "│  ${WHITE}None${NC}"
            else
                local role=$(echo "$async_status" | cut -d'|' -f1)
                local details=$(echo "$async_status" | cut -d'|' -f2-)
                if [ "$role" = "Replica" ]; then
                    echo -e "│  Role: ${MAGENTA}Replica${NC}"
                    echo "│  $details" | tr '|' '\n' | sed 's/^/│    /'
                else
                    echo -e "│  Role: ${CYAN}Source${NC}"
                    echo -e "│    $details"
                fi
            fi
            
            echo -e "${BOLD}${BLUE}└─────────────────────────────────────────────────────────────────${NC}"
            echo ""
        done
        
        echo -e "${WHITE}Refreshing in ${INTERVAL}s... (Ctrl+C to exit)${NC}"
        sleep "$INTERVAL"
    done
}

# Trap Ctrl+C
trap 'echo -e "\n${YELLOW}Monitoring stopped.${NC}"; exit 0' INT TERM

# Start monitoring
monitor_cluster


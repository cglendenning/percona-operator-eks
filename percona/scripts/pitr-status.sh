#!/bin/bash

# PITR Status Report Script
# Reports the status of Point-in-Time Recovery for a Percona XtraDB Cluster
# Works with both MinIO (on-prem) and S3 (EKS) storage

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
NAMESPACE=""
CLUSTER_NAME=""
KUBECONFIG="${KUBECONFIG:-}"
VERBOSE=false
DETAILED=false

# kubectl wrapper function that always includes --kubeconfig if set
kctl() {
    if [ -n "$KUBECONFIG" ]; then
        kubectl --kubeconfig="$KUBECONFIG" "$@"
    else
        kubectl "$@"
    fi
}

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

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 -n NAMESPACE [-c CLUSTER_NAME] [OPTIONS]

Reports Point-in-Time Recovery (PITR) status for Percona XtraDB Cluster.

This script:
  - Checks PITR pod status and logs
  - Verifies backup storage configuration (MinIO/S3)
  - Lists available full backups with PITRReady status
  - Analyzes binlog continuity and identifies gaps
  - Calculates oldest and latest restorable times
  - Reports any PITR limitations or issues

REQUIRED:
    -n, --namespace NAMESPACE    Kubernetes namespace containing the PXC cluster

OPTIONS:
    -c, --cluster CLUSTER_NAME   Cluster name (default: auto-detect)
    -v, --verbose                Show detailed debug information
    -d, --detailed               Show detailed binlog analysis
    -h, --help                   Show this help message

ENVIRONMENT:
    KUBECONFIG                   Path to kubeconfig file (optional)

EXAMPLES:
    # Basic status check
    $0 -n percona

    # Status for specific cluster with verbose output
    $0 -n prod-db -c my-cluster -v

    # Detailed binlog analysis
    $0 -n craig-test -d

    # Using custom kubeconfig
    KUBECONFIG=~/.kube/prod-config $0 -n percona

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
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -d|--detailed)
            DETAILED=true
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
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Please install jq."
    exit 1
fi

# Check if namespace exists
if ! kctl get namespace "$NAMESPACE" &> /dev/null; then
    log_error "Namespace '$NAMESPACE' not found"
    exit 1
fi

log_header "PITR Status Report"
log_info "Namespace: $NAMESPACE"
log_info "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Auto-detect cluster if not specified
if [ -z "$CLUSTER_NAME" ]; then
    log_verbose "Auto-detecting PXC cluster..."
    CLUSTER_NAME=$(kctl get perconaxtradbcluster -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$CLUSTER_NAME" ]; then
        log_error "No PXC cluster found in namespace '$NAMESPACE'"
        log_info "Specify cluster name with -c option if it exists"
        exit 1
    fi
    
    log_info "Detected cluster: $CLUSTER_NAME"
    echo ""
fi

# Validate cluster exists
if ! kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_error "PXC cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

# ============================================================================
# Section 1: PITR Configuration Check
# ============================================================================
log_header "1. PITR Configuration"

PITR_ENABLED=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.backup.pitr.enabled}' 2>/dev/null || echo "false")
PITR_STORAGE=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.backup.pitr.storageName}' 2>/dev/null || echo "")
PITR_UPLOAD_INTERVAL=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.backup.pitr.timeBetweenUploads}' 2>/dev/null || echo "")

if [ "$PITR_ENABLED" = "true" ]; then
    log_success "PITR is enabled"
    log_info "  Storage: ${PITR_STORAGE:-<not set>}"
    log_info "  Upload interval: ${PITR_UPLOAD_INTERVAL:-<not set>} seconds"
else
    log_error "PITR is NOT enabled in cluster configuration"
    log_info "Enable PITR by setting spec.backup.pitr.enabled=true"
    exit 1
fi

# Get storage configuration
if [ -n "$PITR_STORAGE" ]; then
    STORAGE_TYPE=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.backup.storages.${PITR_STORAGE}.type}" 2>/dev/null || echo "")
    STORAGE_BUCKET=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.backup.storages.${PITR_STORAGE}.s3.bucket}" 2>/dev/null || echo "")
    STORAGE_ENDPOINT=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.backup.storages.${PITR_STORAGE}.s3.endpointUrl}" 2>/dev/null || echo "")
    STORAGE_REGION=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.backup.storages.${PITR_STORAGE}.s3.region}" 2>/dev/null || echo "")
    STORAGE_CREDS=$(kctl get perconaxtradbcluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.backup.storages.${PITR_STORAGE}.s3.credentialsSecret}" 2>/dev/null || echo "")
    
    log_info "  Bucket: ${STORAGE_BUCKET}"
    log_info "  Type: ${STORAGE_TYPE}"
    
    if [ -n "$STORAGE_ENDPOINT" ]; then
        log_info "  Endpoint: ${STORAGE_ENDPOINT} (MinIO/on-prem)"
        STORAGE_MODE="minio"
    else
        log_info "  Region: ${STORAGE_REGION} (AWS S3)"
        STORAGE_MODE="s3"
    fi
    
    log_verbose "  Credentials secret: ${STORAGE_CREDS}"
    
    # Verify credentials secret exists
    if [ -n "$STORAGE_CREDS" ]; then
        if kctl get secret "$STORAGE_CREDS" -n "$NAMESPACE" &>/dev/null; then
            log_success "  Credentials secret exists"
        else
            log_error "  Credentials secret '$STORAGE_CREDS' not found"
        fi
    fi
else
    log_error "PITR storage name not specified"
    exit 1
fi

# ============================================================================
# Section 2: PITR Pod Status
# ============================================================================
log_header "2. PITR Pod Status"

PITR_POD=$(kctl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pitr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$PITR_POD" ]; then
    log_error "No PITR pod found"
    log_info "PITR pod should exist when pitr.enabled=true"
    PITR_POD_STATUS="NotFound"
else
    POD_STATUS=$(kctl get pod "$PITR_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    POD_READY=$(kctl get pod "$PITR_POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    POD_RESTARTS=$(kctl get pod "$PITR_POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    
    log_info "Pod: $PITR_POD"
    log_info "  Phase: $POD_STATUS"
    log_info "  Ready: $POD_READY"
    log_info "  Restarts: $POD_RESTARTS"
    
    if [ "$POD_STATUS" = "Running" ] && [ "$POD_READY" = "true" ]; then
        log_success "PITR pod is healthy"
        PITR_POD_STATUS="Running"
    elif [ "$POD_STATUS" = "Running" ]; then
        log_warn "PITR pod is running but not ready"
        PITR_POD_STATUS="NotReady"
    else
        log_error "PITR pod is not running (status: $POD_STATUS)"
        PITR_POD_STATUS="Failed"
    fi
    
    if [ "$POD_RESTARTS" -gt 0 ]; then
        log_warn "PITR pod has restarted $POD_RESTARTS times (check logs)"
    fi
fi

# ============================================================================
# Section 3: PITR Container Logs Analysis
# ============================================================================
log_header "3. PITR Container Logs"

if [ -n "$PITR_POD" ] && [ "$PITR_POD_STATUS" != "NotFound" ]; then
    log_info "Analyzing recent logs from PITR container..."
    echo ""
    
    # Get last 30 lines of logs
    PITR_LOGS=$(kctl logs "$PITR_POD" -n "$NAMESPACE" -c pitr --tail=30 2>/dev/null || echo "")
    
    if [ -n "$PITR_LOGS" ]; then
        # Look for key indicators
        UPLOAD_SUCCESS=$(echo "$PITR_LOGS" | grep -i "upload.*success\|uploaded" | tail -1 || echo "")
        UPLOAD_ERROR=$(echo "$PITR_LOGS" | grep -i "error\|fail" | tail -1 || echo "")
        LAST_BINLOG=$(echo "$PITR_LOGS" | grep -oE "mysql-bin\.[0-9]+" | tail -1 || echo "")
        LAST_GTID=$(echo "$PITR_LOGS" | grep -oE "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}:[0-9]+-[0-9]+" | tail -1 || echo "")
        
        if [ -n "$UPLOAD_SUCCESS" ]; then
            log_success "Recent successful upload detected"
            log_verbose "  $UPLOAD_SUCCESS"
        fi
        
        if [ -n "$UPLOAD_ERROR" ]; then
            log_error "Recent error detected in logs"
            log_info "  $UPLOAD_ERROR"
        fi
        
        if [ -n "$LAST_BINLOG" ]; then
            log_info "  Last binlog: $LAST_BINLOG"
        fi
        
        if [ -n "$LAST_GTID" ]; then
            log_info "  Last GTID: $LAST_GTID"
        fi
        
        if [ "$VERBOSE" = true ]; then
            echo ""
            log_verbose "Recent log excerpt:"
            echo "$PITR_LOGS" | tail -10 | sed 's/^/    /'
        fi
    else
        log_warn "Could not retrieve PITR container logs"
    fi
else
    log_warn "Skipping log analysis (PITR pod not available)"
fi

# ============================================================================
# Section 4: Available Backups Analysis
# ============================================================================
log_header "4. Available Backups"

log_info "Querying backup resources..."

# Get all backup resources
BACKUPS_JSON=$(kctl get perconaxtradbclusterbackup -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
BACKUP_COUNT=$(echo "$BACKUPS_JSON" | jq '.items | length')

log_info "Found $BACKUP_COUNT backup(s)"
echo ""

if [ "$BACKUP_COUNT" -eq 0 ]; then
    log_warn "No backups found in namespace '$NAMESPACE'"
    log_info "PITR requires at least one full backup as a base"
    log_info "Create a backup with: kubectl apply -f backup.yaml"
    exit 0
fi

# Analyze each backup
PITR_READY_BACKUPS=()
PITR_NOT_READY_BACKUPS=()
LATEST_PITR_READY_BACKUP=""
LATEST_PITR_READY_TIME=""

for i in $(seq 0 $((BACKUP_COUNT - 1))); do
    BACKUP_NAME=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].metadata.name")
    BACKUP_STATE=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].status.state // \"Unknown\"")
    BACKUP_COMPLETED=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].status.completed // \"\"")
    BACKUP_STORAGE=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].spec.storageName // \"\"")
    
    # Check PITRReady condition
    PITR_READY_STATUS=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].status.conditions[] | select(.type==\"PITRReady\") | .status" 2>/dev/null || echo "")
    PITR_READY_REASON=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].status.conditions[] | select(.type==\"PITRReady\") | .reason" 2>/dev/null || echo "")
    PITR_READY_MESSAGE=$(echo "$BACKUPS_JSON" | jq -r ".items[$i].status.conditions[] | select(.type==\"PITRReady\") | .message" 2>/dev/null || echo "")
    
    echo "Backup: $BACKUP_NAME"
    echo "  State: $BACKUP_STATE"
    echo "  Completed: ${BACKUP_COMPLETED:-<in progress>}"
    echo "  Storage: $BACKUP_STORAGE"
    
    if [ "$BACKUP_STATE" = "Succeeded" ]; then
        if [ "$PITR_READY_STATUS" = "True" ]; then
            log_success "  PITR Ready: Yes"
            PITR_READY_BACKUPS+=("$BACKUP_NAME|$BACKUP_COMPLETED")
            
            # Track latest PITR-ready backup
            if [ -z "$LATEST_PITR_READY_BACKUP" ] || [[ "$BACKUP_COMPLETED" > "$LATEST_PITR_READY_TIME" ]]; then
                LATEST_PITR_READY_BACKUP="$BACKUP_NAME"
                LATEST_PITR_READY_TIME="$BACKUP_COMPLETED"
            fi
        elif [ "$PITR_READY_STATUS" = "False" ]; then
            log_error "  PITR Ready: No"
            log_warn "  Reason: $PITR_READY_REASON"
            if [ -n "$PITR_READY_MESSAGE" ]; then
                log_info "  Message: $PITR_READY_MESSAGE"
            fi
            PITR_NOT_READY_BACKUPS+=("$BACKUP_NAME|$BACKUP_COMPLETED|$PITR_READY_REASON")
        else
            log_info "  PITR Ready: Unknown (no PITRReady condition)"
        fi
    else
        log_warn "  Backup not completed (state: $BACKUP_STATE)"
    fi
    echo ""
done

# ============================================================================
# Section 5: Binlog Continuity Analysis
# ============================================================================
log_header "5. Binlog Continuity Analysis"

BINLOG_COUNT_ACTUAL=0
BINLOG_LIST=""
MC_AVAILABLE=false
GAP_FOUND=false
OLDEST_BINLOG=""
NEWEST_BINLOG=""
OLDEST_BINLOG_DATE=""
NEWEST_BINLOG_DATE=""

if [ "$STORAGE_MODE" = "minio" ]; then
    log_info "Storage type: MinIO (on-prem)"
    
    # Check if we can use mc for direct verification
    MINIO_POD=$(kctl get pods -n minio-operator -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$MINIO_POD" ]; then
        # Try legacy namespace
        MINIO_POD=$(kctl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        MINIO_NS="minio"
    else
        MINIO_NS="minio-operator"
    fi
    
    if [ -n "$MINIO_POD" ]; then
        log_info "Found MinIO pod: $MINIO_POD"
        log_info "Attempting direct binlog verification using mc..."
        
        # Get MinIO credentials from secret
        if [ -n "$STORAGE_CREDS" ]; then
            MINIO_ACCESS_KEY=$(kctl get secret "$STORAGE_CREDS" -n "$NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            MINIO_SECRET_KEY=$(kctl get secret "$STORAGE_CREDS" -n "$NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            
            if [ -z "$MINIO_ACCESS_KEY" ]; then
                # Try alternate key names
                MINIO_ACCESS_KEY=$(kctl get secret "$STORAGE_CREDS" -n "$NAMESPACE" -o jsonpath='{.data.accesskey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
                MINIO_SECRET_KEY=$(kctl get secret "$STORAGE_CREDS" -n "$NAMESPACE" -o jsonpath='{.data.secretkey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            fi
            
            if [ -n "$MINIO_ACCESS_KEY" ] && [ -n "$MINIO_SECRET_KEY" ]; then
                log_verbose "Retrieved MinIO credentials from secret"
                
                # Configure mc alias
                MC_ALIAS="pitr-verify-$$"
                MC_ENDPOINT=$(echo "$STORAGE_ENDPOINT" | sed 's|https://|http://|')
                
                log_verbose "Configuring mc alias: $MC_ALIAS"
                
                if kctl exec -n "$MINIO_NS" "$MINIO_POD" -- mc alias set "$MC_ALIAS" "$MC_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" --insecure &>/dev/null; then
                    log_success "Connected to MinIO via mc"
                    MC_AVAILABLE=true
                    
                    # List binlogs in bucket
                    log_info "Listing binlogs in bucket: $STORAGE_BUCKET"
                    
                    BINLOG_LIST=$(kctl exec -n "$MINIO_NS" "$MINIO_POD" -- mc ls "$MC_ALIAS/$STORAGE_BUCKET/binlog/" --insecure 2>/dev/null || echo "")
                    
                    if [ -n "$BINLOG_LIST" ]; then
                        BINLOG_COUNT_ACTUAL=$(echo "$BINLOG_LIST" | grep -c "mysql-bin\." || echo "0")
                        log_success "Found $BINLOG_COUNT_ACTUAL binlog files in MinIO"
                        
                        if [ "$DETAILED" = true ]; then
                            echo ""
                            log_info "Binlog files (first 20):"
                            echo "$BINLOG_LIST" | grep "mysql-bin\." | head -20 | sed 's/^/    /'
                            
                            if [ "$BINLOG_COUNT_ACTUAL" -gt 20 ]; then
                                log_info "... and $((BINLOG_COUNT_ACTUAL - 20)) more"
                            fi
                        fi
                        
                        # Get oldest and newest binlog
                        OLDEST_BINLOG=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | head -1 | awk '{print $NF}')
                        NEWEST_BINLOG=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | tail -1 | awk '{print $NF}')
                        OLDEST_BINLOG_DATE=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | head -1 | awk '{print $1" "$2}')
                        NEWEST_BINLOG_DATE=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | tail -1 | awk '{print $1" "$2}')
                        
                        echo ""
                        log_info "Binlog range:"
                        log_info "  Oldest: $OLDEST_BINLOG (uploaded: $OLDEST_BINLOG_DATE)"
                        log_info "  Newest: $NEWEST_BINLOG (uploaded: $NEWEST_BINLOG_DATE)"
                        
                        # Check for gaps in binlog sequence
                        log_verbose "Checking for gaps in binlog sequence..."
                        BINLOG_NUMBERS=$(echo "$BINLOG_LIST" | grep -oE "mysql-bin\.([0-9]+)" | grep -oE "[0-9]+" | sort -n)
                        
                        if [ -n "$BINLOG_NUMBERS" ]; then
                            PREV_NUM=""
                            GAP_FOUND=false
                            GAPS=""
                            
                            while IFS= read -r num; do
                                if [ -n "$PREV_NUM" ]; then
                                    EXPECTED=$((PREV_NUM + 1))
                                    if [ "$num" -ne "$EXPECTED" ]; then
                                        GAP_FOUND=true
                                        GAPS="${GAPS}mysql-bin.${EXPECTED} to mysql-bin.$((num - 1))\n"
                                        log_warn "  Gap detected: mysql-bin.${EXPECTED} to mysql-bin.$((num - 1)) are missing"
                                    fi
                                fi
                                PREV_NUM=$num
                            done <<< "$BINLOG_NUMBERS"
                            
                            if [ "$GAP_FOUND" = false ]; then
                                log_success "  No gaps detected in binlog sequence"
                            fi
                        fi
                    else
                        log_warn "No binlogs found in bucket (binlog/ folder may be empty)"
                        BINLOG_COUNT_ACTUAL=0
                    fi
                    
                    # Clean up mc alias
                    kctl exec -n "$MINIO_NS" "$MINIO_POD" -- mc alias remove "$MC_ALIAS" &>/dev/null || true
                else
                    log_warn "Could not configure mc alias (credentials may be incorrect)"
                fi
            else
                log_warn "Could not retrieve MinIO credentials from secret"
            fi
        else
            log_warn "No credentials secret specified"
        fi
    else
        log_warn "MinIO pod not found - cannot verify binlogs directly"
    fi
    
    if [ "$MC_AVAILABLE" = false ]; then
        log_info "Falling back to operator status for binlog analysis"
    fi
    
elif [ "$STORAGE_MODE" = "s3" ]; then
    log_info "Storage type: AWS S3"
    log_info "Direct S3 binlog verification requires AWS CLI (not implemented)"
    log_info "Using PXC operator status for analysis"
fi

echo ""

# Analyze binlog gaps from backup PITRReady conditions
log_info "Operator-reported binlog status:"
echo ""

if [ ${#PITR_NOT_READY_BACKUPS[@]} -gt 0 ]; then
    log_warn "Operator detected ${#PITR_NOT_READY_BACKUPS[@]} backup(s) with binlog gaps:"
    echo ""
    
    for backup_info in "${PITR_NOT_READY_BACKUPS[@]}"; do
        IFS='|' read -r name time reason <<< "$backup_info"
        echo "  Backup: $name"
        echo "  Time: $time"
        echo "  Issue: $reason"
        echo ""
    done
    
    log_info "Binlog gaps mean PITR cannot restore to points in the gap period"
else
    log_success "Operator reports: No binlog gaps in completed backups"
fi

# Compare direct verification with operator status if available
if [ "$MC_AVAILABLE" = true ] && [ "$BINLOG_COUNT_ACTUAL" -gt 0 ]; then
    echo ""
    log_info "Direct verification summary:"
    log_info "  Binlogs in storage: $BINLOG_COUNT_ACTUAL files"
    log_info "  Operator-reported gaps: ${#PITR_NOT_READY_BACKUPS[@]} backup(s) affected"
    
    if [ ${#PITR_NOT_READY_BACKUPS[@]} -gt 0 ] && [ "$GAP_FOUND" = false ]; then
        echo ""
        log_warn "DRIFT DETECTED:"
        log_warn "  Operator reports gaps, but direct verification found continuous sequence"
        log_info "  This may indicate:"
        log_info "    - Gaps were in older binlogs that have been purged"
        log_info "    - Operator detected gaps during backup, now resolved"
        log_info "    - Binlog numbering restarted after maintenance"
    elif [ ${#PITR_NOT_READY_BACKUPS[@]} -eq 0 ] && [ "$GAP_FOUND" = true ]; then
        echo ""
        log_warn "DRIFT DETECTED:"
        log_warn "  Direct verification found gaps, but operator reports no issues"
        log_info "  This may indicate:"
        log_info "    - Gaps are in older binlogs before the oldest backup"
        log_info "    - These gaps don't affect current PITR capability"
        log_info "    - Binlogs were manually deleted/managed"
    fi
fi

# ============================================================================
# Section 6: Restorable Time Windows
# ============================================================================
log_header "6. Restorable Time Windows"

if [ ${#PITR_READY_BACKUPS[@]} -eq 0 ]; then
    log_error "No PITR-ready backups available"
    log_info "Cannot perform point-in-time recovery"
    log_info ""
    log_info "Action items:"
    log_info "  1. Ensure PITR is enabled and configured correctly"
    log_info "  2. Wait for at least one full backup to complete"
    log_info "  3. Ensure binlogs are uploading continuously"
    log_info "  4. Check PITR pod logs for errors"
else
    log_success "${#PITR_READY_BACKUPS[@]} PITR-ready backup(s) available"
    echo ""
    
    # Find oldest restorable time
    OLDEST_BACKUP_TIME=""
    OLDEST_BACKUP_NAME=""
    
    for backup_info in "${PITR_READY_BACKUPS[@]}"; do
        IFS='|' read -r name time <<< "$backup_info"
        if [ -z "$OLDEST_BACKUP_TIME" ] || [[ "$time" < "$OLDEST_BACKUP_TIME" ]]; then
            OLDEST_BACKUP_TIME="$time"
            OLDEST_BACKUP_NAME="$name"
        fi
    done
    
    # Get current time from MySQL
    CURRENT_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    log_info "Oldest restorable time:"
    log_success "  $OLDEST_BACKUP_TIME"
    log_info "  From backup: $OLDEST_BACKUP_NAME"
    echo ""
    
    log_info "Latest restorable time:"
    log_success "  $CURRENT_TIME (approximately)"
    log_info "  Based on continuous binlog uploads"
    echo ""
    
    log_info "You can restore to ANY point in time between:"
    log_success "  FROM: $OLDEST_BACKUP_TIME"
    log_success "  TO:   $CURRENT_TIME"
    echo ""
    
    # Check for gaps
    if [ ${#PITR_NOT_READY_BACKUPS[@]} -gt 0 ]; then
        log_warn "HOWEVER: Some backups have binlog gaps"
        log_info "Recovery limitations:"
        echo ""
        
        for backup_info in "${PITR_NOT_READY_BACKUPS[@]}"; do
            IFS='|' read -r name time reason <<< "$backup_info"
            
            # Try to parse GTID range from reason if it's a BinlogGapDetected
            if [[ "$reason" == *"BinlogGapDetected"* ]]; then
                log_warn "  Gap detected around backup: $name ($time)"
                log_info "  You CANNOT restore to times immediately after this backup"
                log_info "  until a later PITR-ready backup was taken"
            fi
        done
        echo ""
        
        # Explain recovery strategy
        log_info "Recovery strategy with gaps:"
        log_info "  - Later PITR-ready backups can be used as new starting points"
        log_info "  - Each PITR-ready backup resets the binlog chain"
        log_info "  - Use the most recent PITR-ready backup before your target time"
        echo ""
        
        if [ -n "$LATEST_PITR_READY_BACKUP" ]; then
            log_info "Most recent PITR-ready backup:"
            log_success "  $LATEST_PITR_READY_BACKUP"
            log_info "  Completed: $LATEST_PITR_READY_TIME"
            log_info "  You can safely restore to any point after this time"
        fi
    fi
fi

# ============================================================================
# Section 7: PITR Restore Example
# ============================================================================
if [ ${#PITR_READY_BACKUPS[@]} -gt 0 ]; then
    log_header "7. How to Restore"
    
    echo "To restore to a specific point in time, create a restore resource:"
    echo ""
    cat << EOF
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterRestore
metadata:
  name: restore-pitr-$(date +%Y%m%d-%H%M%S)
  namespace: $NAMESPACE
spec:
  pxcCluster: $CLUSTER_NAME
  backupName: $LATEST_PITR_READY_BACKUP
  pitr:
    type: date
    date: "YYYY-MM-DD HH:MM:SS"
    backupSource:
      storageName: $PITR_STORAGE
EOF
    echo ""
    log_info "Replace 'YYYY-MM-DD HH:MM:SS' with your desired restore time"
    log_info "Apply with: kubectl apply -f restore.yaml"
    echo ""
fi

# ============================================================================
# Summary
# ============================================================================
log_header "Summary"

echo "PITR Status: "
if [ "$PITR_ENABLED" = "true" ] && [ "$PITR_POD_STATUS" = "Running" ] && [ ${#PITR_READY_BACKUPS[@]} -gt 0 ]; then
    log_success "PITR is operational and ready"
elif [ "$PITR_ENABLED" = "true" ] && [ "$PITR_POD_STATUS" = "Running" ] && [ ${#PITR_READY_BACKUPS[@]} -eq 0 ]; then
    log_warn "PITR is configured but no PITR-ready backups exist yet"
    log_info "Wait for a full backup to complete with continuous binlogs"
elif [ "$PITR_ENABLED" = "true" ] && [ "$PITR_POD_STATUS" != "Running" ]; then
    log_error "PITR is configured but pod is not running"
    log_info "Check PITR pod status and logs"
else
    log_error "PITR is not properly configured"
fi

echo ""
log_info "PITR Components:"
log_info "  Configuration: $([ "$PITR_ENABLED" = "true" ] && echo "✓ Enabled" || echo "✗ Disabled")"
log_info "  PITR Pod: $([ "$PITR_POD_STATUS" = "Running" ] && echo "✓ Running" || echo "✗ Not Running")"
log_info "  PITR-Ready Backups: ${#PITR_READY_BACKUPS[@]}"
log_info "  Backups with Gaps: ${#PITR_NOT_READY_BACKUPS[@]}"

if [ "$MC_AVAILABLE" = true ]; then
    log_info "  Binlogs in Storage: $BINLOG_COUNT_ACTUAL files (verified via mc)"
elif [ "$STORAGE_MODE" = "minio" ]; then
    log_info "  Binlogs in Storage: Not verified (mc not available)"
else
    log_info "  Binlogs in Storage: Not verified (S3 mode)"
fi

if [ ${#PITR_READY_BACKUPS[@]} -gt 0 ]; then
    echo ""
    log_info "Restorable Window:"
    log_info "  Oldest: $OLDEST_BACKUP_TIME"
    log_info "  Latest: ~$CURRENT_TIME"
fi

echo ""
log_info "For detailed PITR documentation:"
log_info "  https://docs.percona.com/percona-operator-for-mysql/pxc/backups-pitr.html"
echo ""

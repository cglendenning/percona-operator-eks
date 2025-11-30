#!/bin/bash

# Backup Checker Tool
# Verifies that XtraBackup and PITR backups exist in MinIO storage
# Works with on-prem MinIO deployments
# READ-ONLY: This script only performs read operations (ls, stat) - no destructive operations

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
SECRET_NAME=""
KUBECONFIG="${KUBECONFIG:-}"
VERBOSE=false
MINIO_NAMESPACE=""
MINIO_POD=""

# kubectl wrapper function that always includes --kubeconfig if set
kctl() {
    if [ -n "$KUBECONFIG" ]; then
        kubectl --kubeconfig="$KUBECONFIG" "$@"
    else
        kubectl "$@"
    fi
}

# Execute mc command inside MinIO pod
mc_exec() {
    if [ -z "$MINIO_POD" ] || [ -z "$MINIO_NAMESPACE" ]; then
        log_error "MinIO pod not found"
        return 1
    fi
    kctl exec -n "$MINIO_NAMESPACE" "$MINIO_POD" -- mc "$@"
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
Usage: $0 -n NAMESPACE -s SECRET_NAME [OPTIONS]

Verifies that XtraBackup and PITR backups exist in MinIO storage.

This script:
  - Lists all PerconaXtraDBClusterBackup resources in the namespace
  - Extracts backup paths from backup status
  - Verifies each backup exists in MinIO using mc (executed in MinIO pod)
  - Checks PITR binlog files are present in MinIO
  - Reports any missing backups or binlogs

READ-ONLY OPERATIONS:
  This script only performs read operations (ls, stat) - no destructive operations.
  All mc commands are executed inside the MinIO pod for security.

REQUIRED:
    -n, --namespace NAMESPACE    Kubernetes namespace containing the PXC cluster
    -s, --secret SECRET_NAME     Secret name containing AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY

OPTIONS:
    --kubeconfig PATH             Path to kubeconfig file (optional)
    -v, --verbose                Show detailed debug information
    -h, --help                   Show this help message

ENVIRONMENT:
    KUBECONFIG                   Path to kubeconfig file (optional, overridden by --kubeconfig)

EXAMPLES:
    # Basic backup check
    $0 -n percona -s minio-creds

    # Verbose output with custom kubeconfig
    $0 -n prod-db -s backup-secret --kubeconfig /path/to/kubeconfig -v

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -s|--secret)
            SECRET_NAME="$2"
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$NAMESPACE" ] || [ -z "$SECRET_NAME" ]; then
    log_error "Missing required arguments"
    usage
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    log_error "jq is not installed or not in PATH"
    log_error "Install from: https://stedolan.github.io/jq/download/"
    exit 1
fi

# Verify namespace exists
if ! kctl get namespace "$NAMESPACE" &> /dev/null; then
    log_error "Namespace '$NAMESPACE' does not exist"
    exit 1
fi

# Verify secret exists
if ! kctl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
    log_error "Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

# Get MinIO credentials from secret
log_header "Retrieving MinIO Credentials"

AWS_ACCESS_KEY_ID=$(kctl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
AWS_SECRET_ACCESS_KEY=$(kctl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    log_error "Failed to extract AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY from secret '$SECRET_NAME'"
    log_error "Secret must contain AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY keys"
    exit 1
fi

log_success "MinIO credentials retrieved from secret"

# Get PXC cluster to determine backup storage configuration
log_header "Finding PXC Cluster"

PXC_CLUSTER=$(kctl get perconaxtradbcluster -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$PXC_CLUSTER" ]; then
    log_error "No PerconaXtraDBCluster found in namespace '$NAMESPACE'"
    exit 1
fi

log_success "Found PXC cluster: $PXC_CLUSTER"

# Get backup storage configuration
MINIO_ENDPOINT=$(kctl get perconaxtradbcluster "$PXC_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.s3.endpointUrl}' 2>/dev/null || echo "")
MINIO_BUCKET=$(kctl get perconaxtradbcluster "$PXC_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.s3.bucket}' 2>/dev/null || echo "")

if [ -z "$MINIO_ENDPOINT" ] || [ -z "$MINIO_BUCKET" ]; then
    log_error "Failed to get MinIO endpoint or bucket from PXC cluster configuration"
    log_error "Endpoint: ${MINIO_ENDPOINT:-<not set>}"
    log_error "Bucket: ${MINIO_BUCKET:-<not set>}"
    exit 1
fi

log_info "MinIO Endpoint: $MINIO_ENDPOINT"
log_info "MinIO Bucket: $MINIO_BUCKET"

# Extract MinIO namespace from endpoint (e.g., http://minio.minio.svc.cluster.local:9000 -> minio)
# Try common patterns
MINIO_NAMESPACE=$(echo "$MINIO_ENDPOINT" | sed -n 's|.*://[^.]*\.\([^.]*\)\.svc.*|\1|p' || echo "")

# If we couldn't extract from endpoint, try common namespaces
if [ -z "$MINIO_NAMESPACE" ]; then
    for ns in minio minio-operator minio-system; do
        if kctl get namespace "$ns" &> /dev/null; then
            MINIO_NAMESPACE="$ns"
            log_verbose "Using MinIO namespace: $ns"
            break
        fi
    done
fi

if [ -z "$MINIO_NAMESPACE" ]; then
    log_error "Could not determine MinIO namespace from endpoint: $MINIO_ENDPOINT"
    log_error "Please ensure MinIO is installed and accessible"
    exit 1
fi

log_info "MinIO Namespace: $MINIO_NAMESPACE"

# Find MinIO pod
log_header "Finding MinIO Pod"

MINIO_POD=$(kctl get pods -n "$MINIO_NAMESPACE" -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

# Try alternative label selectors
if [ -z "$MINIO_POD" ]; then
    MINIO_POD=$(kctl get pods -n "$MINIO_NAMESPACE" -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "$MINIO_POD" ]; then
    MINIO_POD=$(kctl get pods -n "$MINIO_NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "$MINIO_POD" ]; then
    log_error "No MinIO pod found in namespace '$MINIO_NAMESPACE'"
    log_error "Available pods:"
    kctl get pods -n "$MINIO_NAMESPACE" 2>/dev/null || true
    exit 1
fi

log_success "Found MinIO pod: $MINIO_POD"

# Verify pod is running
POD_STATUS=$(kctl get pod "$MINIO_POD" -n "$MINIO_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$POD_STATUS" != "Running" ]; then
    log_warn "MinIO pod is not in Running state (status: $POD_STATUS)"
fi

# Configure mc alias inside MinIO pod
log_header "Configuring MinIO Client"

# Remove http:// or https:// prefix for mc alias
MINIO_HOST=$(echo "$MINIO_ENDPOINT" | sed 's|^https\?://||' | sed 's|:.*$||')
MINIO_PORT=$(echo "$MINIO_ENDPOINT" | sed 's|^https\?://||' | sed 's|.*:||' | sed 's|/.*$||')

if [ -z "$MINIO_PORT" ] || [ "$MINIO_PORT" = "$MINIO_HOST" ]; then
    MINIO_PORT="9000"
fi

# Determine if HTTPS
if echo "$MINIO_ENDPOINT" | grep -q "^https://"; then
    MC_ENDPOINT="https://${MINIO_HOST}:${MINIO_PORT}"
else
    MC_ENDPOINT="http://${MINIO_HOST}:${MINIO_PORT}"
fi

# Use localhost from inside the pod if it's a service endpoint
if echo "$MC_ENDPOINT" | grep -q "\.svc\.cluster\.local"; then
    MC_ENDPOINT="http://localhost:9000"
fi

MC_ALIAS="backup-checker-$(date +%s)"

log_verbose "Setting up mc alias: $MC_ALIAS -> $MC_ENDPOINT"

# Configure mc alias inside pod (suppress output)
if ! mc_exec alias set "$MC_ALIAS" "$MC_ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" &> /dev/null; then
    log_error "Failed to configure mc alias inside MinIO pod"
    exit 1
fi

log_success "MinIO client configured"

# Cleanup function
cleanup() {
    log_verbose "Cleaning up mc alias"
    mc_exec alias remove "$MC_ALIAS" &> /dev/null || true
}

trap cleanup EXIT

# Verify bucket exists (READ-ONLY: ls command)
log_header "Verifying MinIO Bucket"

if ! mc_exec ls "$MC_ALIAS/$MINIO_BUCKET" &> /dev/null; then
    log_error "Bucket '$MINIO_BUCKET' does not exist or is not accessible"
    exit 1
fi

log_success "Bucket '$MINIO_BUCKET' is accessible"

# Get all backups
log_header "Checking XtraBackup Full Backups"

BACKUPS=$(kctl get perconaxtradbclusterbackup -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

BACKUP_COUNT=$(echo "$BACKUPS" | jq -r '.items | length' 2>/dev/null || echo "0")

MISSING_BACKUPS=0
VERIFIED_BACKUPS=0

if [ "$BACKUP_COUNT" -eq 0 ]; then
    log_warn "No PerconaXtraDBClusterBackup resources found in namespace '$NAMESPACE'"
else
    log_info "Found $BACKUP_COUNT backup(s)"
    echo ""

    # Process each backup (use process substitution to avoid subshell issues)
    while IFS= read -r backup_b64; do
        BACKUP_JSON=$(echo "$backup_b64" | base64 -d 2>/dev/null || echo "")
        
        BACKUP_NAME=$(echo "$BACKUP_JSON" | jq -r '.metadata.name' 2>/dev/null || echo "")
        BACKUP_STATUS=$(echo "$BACKUP_JSON" | jq -r '.status.state' 2>/dev/null || echo "")
        
        # Try multiple possible path fields from backup status
        BACKUP_PATH=$(echo "$BACKUP_JSON" | jq -r '.status.destination // .status.s3.path // .status.path // ""' 2>/dev/null || echo "")
        
        if [ -z "$BACKUP_NAME" ]; then
            continue
        fi

        echo -n "  Checking backup: $BACKUP_NAME "
        
        if [ "$BACKUP_STATUS" != "ready" ] && [ "$BACKUP_STATUS" != "Succeeded" ]; then
            log_warn "(status: $BACKUP_STATUS)"
            continue
        fi

        # If no explicit path, construct from backup name
        if [ -z "$BACKUP_PATH" ]; then
            BACKUP_PATH="$BACKUP_NAME"
        fi

        # Normalize the path - remove s3:// prefix and bucket name if present
        # Handle cases like: s3://bucket/path, bucket/path, /bucket/path, etc.
        BACKUP_PATH=$(echo "$BACKUP_PATH" | sed 's|^s3://||' | sed "s|^${MINIO_BUCKET}/||" | sed 's|^/||' | sed 's|/$||')
        
        log_verbose "    Raw path from status: $(echo "$BACKUP_JSON" | jq -r '.status.destination // .status.s3.path // .status.path // "<not set>"' 2>/dev/null || echo "<error>")"
        log_verbose "    Normalized path: $BACKUP_PATH"

        # Check if backup exists in MinIO (READ-ONLY: ls command)
        # Try both with and without trailing slash
        BACKUP_FILES=""
        if mc_exec ls "$MC_ALIAS/$MINIO_BUCKET/$BACKUP_PATH" &> /dev/null; then
            BACKUP_FILES=$(mc_exec ls -r "$MC_ALIAS/$MINIO_BUCKET/$BACKUP_PATH" 2>/dev/null || echo "")
        elif mc_exec ls "$MC_ALIAS/$MINIO_BUCKET/$BACKUP_PATH/" &> /dev/null; then
            BACKUP_FILES=$(mc_exec ls -r "$MC_ALIAS/$MINIO_BUCKET/$BACKUP_PATH/" 2>/dev/null || echo "")
        fi
        
        if [ -n "$BACKUP_FILES" ]; then
            log_success "(found)"
            VERIFIED_BACKUPS=$((VERIFIED_BACKUPS + 1))
            
            # Count files by type - use simple loop counting for reliability
            TOTAL_FILES=0
            XTRABACKUP_FILES=0
            METADATA_FILES=0
            BINLOG_FILES=0
            
            if [ -n "$BACKUP_FILES" ]; then
                while IFS= read -r line; do
                    if [ -n "$line" ]; then
                        TOTAL_FILES=$((TOTAL_FILES + 1))
                        case "$line" in
                            *\.qp|*\.xbstream|*\.tar\.gz|*\.tar)
                                XTRABACKUP_FILES=$((XTRABACKUP_FILES + 1))
                                ;;
                            *xtrabackup_info*|*xtrabackup_checkpoints*|*backup-my\.cnf*|*stream-metadata*)
                                METADATA_FILES=$((METADATA_FILES + 1))
                                ;;
                            *mysql-bin\.*)
                                BINLOG_FILES=$((BINLOG_FILES + 1))
                                ;;
                        esac
                    fi
                done <<< "$BACKUP_FILES"
            fi
            
            # Calculate other files
            OTHER_FILES=$((TOTAL_FILES - XTRABACKUP_FILES - METADATA_FILES - BINLOG_FILES))
            
            echo ""
            echo "    Files found: $TOTAL_FILES total"
            if [ "$XTRABACKUP_FILES" -gt 0 ]; then
                echo "      - XtraBackup files (.qp, .xbstream, .tar.gz, .tar): $XTRABACKUP_FILES"
            fi
            if [ "$METADATA_FILES" -gt 0 ]; then
                echo "      - Metadata files (xtrabackup_info, checkpoints, etc.): $METADATA_FILES"
            fi
            if [ "$BINLOG_FILES" -gt 0 ]; then
                echo "      - Binlog files: $BINLOG_FILES"
            fi
            if [ "$OTHER_FILES" -gt 0 ]; then
                echo "      - Other files: $OTHER_FILES"
            fi
        else
            log_error "(missing)"
            log_error "    Expected path: $MINIO_BUCKET/$BACKUP_PATH"
            if [ "$VERBOSE" = true ]; then
                log_verbose "    Raw backup path from status: $(echo "$BACKUP_JSON" | jq -r '.status.destination // .status.s3.path // "<not set>"' 2>/dev/null || echo "<error>")"
                log_verbose "    Attempting to list bucket contents..."
                mc_exec ls "$MC_ALIAS/$MINIO_BUCKET/" 2>/dev/null | head -20 || true
            fi
            MISSING_BACKUPS=$((MISSING_BACKUPS + 1))
        fi
    done < <(echo "$BACKUPS" | jq -r '.items[] | @base64' 2>/dev/null)

    echo ""
    if [ "$MISSING_BACKUPS" -eq 0 ]; then
        log_success "All $VERIFIED_BACKUPS backup(s) verified in MinIO"
    else
        log_error "$MISSING_BACKUPS backup(s) missing from MinIO"
    fi
fi

# Check PITR binlogs (READ-ONLY: ls command)
log_header "Checking PITR Binlog Files"

# Get PITR pod to check binlog status
PITR_POD=$(kctl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pitr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$PITR_POD" ]; then
    log_warn "No PITR pod found in namespace '$NAMESPACE'"
    log_warn "Skipping PITR binlog verification"
else
    log_info "Found PITR pod: $PITR_POD"
    
    # PITR binlogs are stored in binlog/ directory (not binlog_${CLUSTER_NAME})
    PITR_BINLOG_PATH="binlog"
    
    log_info "Checking PITR binlog path: $MINIO_BUCKET/$PITR_BINLOG_PATH"
    
    # List binlog files (READ-ONLY: ls command)
    BINLOG_LIST=$(mc_exec ls -r "$MC_ALIAS/$MINIO_BUCKET/$PITR_BINLOG_PATH/" 2>/dev/null || echo "")
    BINLOG_COUNT=$(echo "$BINLOG_LIST" | grep -E "mysql-bin\." | wc -l | tr -d ' ' || echo "0")
    
    if [ "$BINLOG_COUNT" -gt 0 ]; then
        log_success "Found $BINLOG_COUNT PITR binlog file(s)"
        
        # Get oldest and newest binlog
        OLDEST_BINLOG=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | head -1 | awk '{print $NF}' || echo "")
        NEWEST_BINLOG=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | tail -1 | awk '{print $NF}' || echo "")
        OLDEST_DATE=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | head -1 | awk '{print $1" "$2}' || echo "")
        NEWEST_DATE=$(echo "$BINLOG_LIST" | grep "mysql-bin\." | tail -1 | awk '{print $1" "$2}' || echo "")
        
        if [ -n "$OLDEST_BINLOG" ] && [ -n "$NEWEST_BINLOG" ]; then
            echo ""
            echo "    Binlog range:"
            echo "      - Oldest: $OLDEST_BINLOG (uploaded: $OLDEST_DATE)"
            echo "      - Newest: $NEWEST_BINLOG (uploaded: $NEWEST_DATE)"
        fi
        
        if [ "$VERBOSE" = true ]; then
            echo ""
            log_info "Recent binlog files (last 10):"
            echo "$BINLOG_LIST" | grep "mysql-bin\." | tail -10 | while read -r line; do
                echo "    $line"
            done
        fi
    else
        log_warn "No PITR binlog files found in $MINIO_BUCKET/$PITR_BINLOG_PATH"
        log_warn "This may indicate PITR is not running or binlogs are not being uploaded"
        
        if [ "$VERBOSE" = true ]; then
            log_verbose "Listing contents of binlog directory:"
            mc_exec ls "$MC_ALIAS/$MINIO_BUCKET/$PITR_BINLOG_PATH/" 2>/dev/null | head -20 || true
        fi
    fi
fi

# Summary
log_header "Summary"

echo "Namespace: $NAMESPACE"
echo "PXC Cluster: $PXC_CLUSTER"
echo "MinIO Bucket: $MINIO_BUCKET"
echo "MinIO Endpoint: $MINIO_ENDPOINT"
echo "MinIO Pod: $MINIO_POD (namespace: $MINIO_NAMESPACE)"
echo ""

if [ "$MISSING_BACKUPS" -gt 0 ]; then
    log_error "Some backups are missing from MinIO storage"
    exit 1
else
    log_success "All backups verified successfully"
    exit 0
fi

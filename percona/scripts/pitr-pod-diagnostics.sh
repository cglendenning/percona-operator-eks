#!/bin/bash
# PITR Pod Diagnostics Script
# Diagnoses common issues with Percona XtraDB Cluster PITR pods

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# Parse command line arguments
NAMESPACE=""
CLUSTER_NAME=""

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Diagnose PITR pod issues in Percona XtraDB Cluster

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (required)
    -c, --cluster CLUSTER_NAME   Cluster name (default: pxc-cluster)
    -h, --help                   Show this help message

EXAMPLES:
    $0 -n prod
    $0 -n craig-test -c my-pxc-cluster
    $0 --namespace percona --cluster pxc-cluster

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

# Set default cluster name if not provided
CLUSTER_NAME="${CLUSTER_NAME:-pxc-cluster}"

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
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    log_error "Namespace '$NAMESPACE' not found"
    exit 1
fi

# Main diagnostics
log_header "PITR Pod Diagnostics"
log_info "Namespace: $NAMESPACE"
log_info "Cluster: $CLUSTER_NAME"
echo ""

# 1. PITR Pod Status
log_header "1. PITR Pod Status"
PITR_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pitr --no-headers 2>/dev/null || echo "")

if [ -z "$PITR_PODS" ]; then
    log_error "No PITR pods found in namespace '$NAMESPACE'"
    log_info "This could mean:"
    log_info "  - PITR is not enabled in the cluster configuration"
    log_info "  - The cluster hasn't finished deploying yet"
    log_info "  - The label selector is incorrect"
    exit 1
fi

echo "$PITR_PODS" | while read -r line; do
    POD_NAME=$(echo "$line" | awk '{print $1}')
    READY=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')
    RESTARTS=$(echo "$line" | awk '{print $4}')
    AGE=$(echo "$line" | awk '{print $5}')
    
    echo "Pod: $POD_NAME"
    echo "  Ready: $READY"
    echo "  Status: $STATUS"
    echo "  Restarts: $RESTARTS"
    echo "  Age: $AGE"
    
    if [[ "$STATUS" == "CrashLoopBackOff" ]]; then
        log_error "Pod is in CrashLoopBackOff state!"
    elif [[ "$STATUS" == "Error" ]]; then
        log_error "Pod is in Error state!"
    elif [[ "$STATUS" == "Running" ]] && [[ "$READY" == "1/1" ]]; then
        log_success "Pod is running and ready"
    else
        log_warn "Pod status: $STATUS (Ready: $READY)"
    fi
    
    if [ "$RESTARTS" != "0" ] && [ "$RESTARTS" != "<none>" ]; then
        log_warn "Pod has restarted $RESTARTS times"
    fi
    echo ""
done

# Get first PITR pod for detailed diagnostics
PITR_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pitr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$PITR_POD" ]; then
    log_error "Could not get PITR pod name"
    exit 1
fi

# 2. PITR Pod Logs (Current)
log_header "2. PITR Pod Logs (Current)"
echo "Fetching current logs from: $PITR_POD"
echo ""
if kubectl logs "$PITR_POD" -n "$NAMESPACE" --tail=50 2>/dev/null; then
    echo ""
else
    log_warn "Could not fetch current logs (pod may not be running yet)"
    echo ""
fi

# 3. PITR Pod Logs (Previous/Crashed)
log_header "3. PITR Pod Logs (Previous Container - Last Crash)"
echo "Fetching logs from last crashed container..."
echo ""
if kubectl logs "$PITR_POD" -n "$NAMESPACE" --previous --tail=50 2>/dev/null; then
    echo ""
else
    log_warn "No previous container logs available (pod hasn't crashed or just started)"
    echo ""
fi

# 4. Environment Variables Check
log_header "4. Environment Variables Check"
PITR_DEPLOYMENT="${CLUSTER_NAME}-pxc-db-pitr"

if ! kubectl get deployment "$PITR_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
    log_error "PITR deployment '$PITR_DEPLOYMENT' not found"
else
    log_info "Checking environment variables in deployment: $PITR_DEPLOYMENT"
    echo ""
    
    # Check for GTID_CACHE_KEY
    GTID_KEY=$(kubectl get deployment "$PITR_DEPLOYMENT" -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="GTID_CACHE_KEY") | .value' 2>/dev/null || echo "")
    
    if [ -n "$GTID_KEY" ]; then
        log_success "GTID_CACHE_KEY is set: $GTID_KEY"
    else
        log_error "GTID_CACHE_KEY is MISSING!"
        log_info "This is required for PITR to function"
        log_info "To fix, run: kubectl patch deployment $PITR_DEPLOYMENT -n $NAMESPACE --type=json -p='[{\"op\":\"add\",\"path\": \"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"GTID_CACHE_KEY\",\"value\":\"pxc-pitr-cache\"}}]'"
    fi
    echo ""
    
    # Show all environment variables
    log_info "All environment variables:"
    kubectl get deployment "$PITR_DEPLOYMENT" -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].env[]? | "  \(.name) = \(.value // .valueFrom // "<from secret/configmap>")"' 2>/dev/null || \
        log_warn "Could not retrieve environment variables"
    echo ""
fi

# 5. MinIO/S3 Secret Check
log_header "5. Backup Storage Secret Check"

# Check for MinIO secret
if kubectl get secret percona-backup-minio -n "$NAMESPACE" &>/dev/null; then
    log_success "MinIO secret 'percona-backup-minio' exists"
    
    # Check secret contents
    ACCESS_KEY=$(kubectl get secret percona-backup-minio -n "$NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$ACCESS_KEY" ]; then
        log_success "AWS_ACCESS_KEY_ID is set (length: ${#ACCESS_KEY})"
    else
        log_error "AWS_ACCESS_KEY_ID is missing or empty in secret"
    fi
    
    SECRET_KEY=$(kubectl get secret percona-backup-minio -n "$NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$SECRET_KEY" ]; then
        log_success "AWS_SECRET_ACCESS_KEY is set (length: ${#SECRET_KEY})"
    else
        log_error "AWS_SECRET_ACCESS_KEY is missing or empty in secret"
    fi
else
    log_error "MinIO secret 'percona-backup-minio' NOT found"
    log_info "PITR requires MinIO for backup storage"
fi

# Check for S3 secret (alternative)
if kubectl get secret percona-backup-s3 -n "$NAMESPACE" &>/dev/null; then
    log_success "S3 secret 'percona-backup-s3' exists"
else
    log_info "S3 secret 'percona-backup-s3' not found (OK if using MinIO)"
fi
echo ""

# 6. MinIO Service Check
log_header "6. MinIO Service Check"
if kubectl get namespace minio &>/dev/null; then
    log_success "MinIO namespace exists"
    
    MINIO_PODS=$(kubectl get pods -n minio -l app=minio --no-headers 2>/dev/null || echo "")
    if [ -n "$MINIO_PODS" ]; then
        log_success "MinIO pods found:"
        echo "$MINIO_PODS" | while read -r line; do
            POD_NAME=$(echo "$line" | awk '{print $1}')
            STATUS=$(echo "$line" | awk '{print $3}')
            echo "  - $POD_NAME: $STATUS"
        done
    else
        log_error "No MinIO pods found in minio namespace"
    fi
    
    # Check MinIO service
    if kubectl get service minio -n minio &>/dev/null; then
        log_success "MinIO service exists"
        MINIO_ENDPOINT=$(kubectl get service minio -n minio -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "unknown")
        log_info "MinIO endpoint: http://${MINIO_ENDPOINT}"
    else
        log_error "MinIO service not found"
    fi
else
    log_error "MinIO namespace does not exist"
    log_info "MinIO is required for PITR backup storage"
    log_info "You may need to install MinIO first"
fi
echo ""

# 7. PXC Cluster Configuration
log_header "7. PXC Cluster Backup Configuration"
PXC_RESOURCE="${CLUSTER_NAME}-pxc-db"

if kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" &>/dev/null; then
    log_success "PXC resource '$PXC_RESOURCE' exists"
    
    # Check backup configuration
    BACKUP_STORAGE=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages}' 2>/dev/null || echo "")
    if [ -n "$BACKUP_STORAGE" ] && [ "$BACKUP_STORAGE" != "{}" ]; then
        log_success "Backup storage is configured"
        echo ""
        log_info "Backup storage configuration:"
        kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.backup.storages | to_entries[] | "  Storage: \(.key)\n    Type: \(.value | keys[0])\n    Config: \(.value)"' 2>/dev/null || \
            echo "$BACKUP_STORAGE"
    else
        log_warn "Backup storage configuration is empty or not found"
    fi
    
    # Check PITR enabled
    PITR_ENABLED=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.pitr.enabled}' 2>/dev/null || echo "false")
    if [ "$PITR_ENABLED" = "true" ]; then
        log_success "PITR is enabled in cluster configuration"
    else
        log_error "PITR is NOT enabled in cluster configuration"
        log_info "To enable: kubectl patch perconaxtradbcluster $PXC_RESOURCE -n $NAMESPACE --type=merge -p '{\"spec\":{\"backup\":{\"pitr\":{\"enabled\":true}}}}'"
    fi
else
    log_error "PXC resource '$PXC_RESOURCE' not found"
fi
echo ""

# 8. Recent Events
log_header "8. Recent Pod Events"
kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$PITR_POD" --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || \
    log_warn "Could not retrieve events"
echo ""

# 9. Pod Description (Condensed)
log_header "9. Pod Resource Limits and Status"
kubectl describe pod "$PITR_POD" -n "$NAMESPACE" 2>/dev/null | grep -A 10 "Limits:\|Requests:\|Conditions:\|State:" || \
    log_warn "Could not retrieve pod description"
echo ""

# Summary and Recommendations
log_header "SUMMARY AND RECOMMENDATIONS"

ISSUES=()

# Check for common issues
if ! kubectl get secret percona-backup-minio -n "$NAMESPACE" &>/dev/null; then
    ISSUES+=("MinIO secret is missing")
fi

GTID_CHECK=$(kubectl get deployment "$PITR_DEPLOYMENT" -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="GTID_CACHE_KEY") | .name' 2>/dev/null || echo "")
if [ -z "$GTID_CHECK" ]; then
    ISSUES+=("GTID_CACHE_KEY environment variable is missing")
fi

if ! kubectl get namespace minio &>/dev/null; then
    ISSUES+=("MinIO namespace/service does not exist")
fi

POD_STATUS=$(kubectl get pod "$PITR_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$POD_STATUS" == "CrashLoopBackOff" ]] || [[ "$POD_STATUS" == "Error" ]]; then
    ISSUES+=("PITR pod is in $POD_STATUS state")
fi

if [ ${#ISSUES[@]} -eq 0 ]; then
    log_success "No major issues detected!"
    log_info "If PITR is still not working, check the pod logs above for specific errors."
else
    log_error "Found ${#ISSUES[@]} issue(s):"
    for issue in "${ISSUES[@]}"; do
        echo "  ✗ $issue"
    done
    echo ""
    log_info "Common fixes:"
    log_info "  1. Ensure MinIO is installed and running"
    log_info "  2. Add GTID_CACHE_KEY to PITR deployment"
    log_info "  3. Verify MinIO credentials in secret"
    log_info "  4. Check network connectivity to MinIO service"
fi

echo ""
log_info "For more help, check:"
log_info "  - Percona Operator docs: https://docs.percona.com/percona-operator-for-mysql/pxc/"
log_info "  - PITR documentation: https://docs.percona.com/percona-operator-for-mysql/pxc/backups-pitr.html"
echo ""


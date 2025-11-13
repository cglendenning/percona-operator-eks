#!/bin/bash
# PITR Pod Diagnostics and Repair Script
# Diagnoses and fixes common issues with Percona XtraDB Cluster PITR pods

set -euo pipefail

# Enable fix mode by default
FIX_MODE="true"

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

Diagnose and fix PITR pod issues in Percona XtraDB Cluster

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (required)
    -c, --cluster CLUSTER_NAME   Cluster name (default: pxc-cluster)
    --diagnose-only              Only diagnose, don't attempt fixes
    -h, --help                   Show this help message

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

# Track issues for repair
MINIO_SECRET_MISSING=false
MINIO_SECRET_SOURCE_NS=""

# Check for myminio-creds secret (correct for on-prem)
if kubectl get secret myminio-creds -n "$NAMESPACE" &>/dev/null; then
    log_success "MinIO secret 'myminio-creds' exists"
    
    # Check secret contents
    ACCESS_KEY=$(kubectl get secret myminio-creds -n "$NAMESPACE" -o jsonpath='{.data.accesskey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "$ACCESS_KEY" ]; then
        # Try AWS format
        ACCESS_KEY=$(kubectl get secret myminio-creds -n "$NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    if [ -n "$ACCESS_KEY" ]; then
        log_success "Access key is set (length: ${#ACCESS_KEY})"
    else
        log_error "Access key is missing or empty in secret"
    fi
    
    SECRET_KEY=$(kubectl get secret myminio-creds -n "$NAMESPACE" -o jsonpath='{.data.secretkey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "$SECRET_KEY" ]; then
        # Try AWS format
        SECRET_KEY=$(kubectl get secret myminio-creds -n "$NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    if [ -n "$SECRET_KEY" ]; then
        log_success "Secret key is set (length: ${#SECRET_KEY})"
    else
        log_error "Secret key is missing or empty in secret"
    fi
else
    log_error "MinIO secret 'myminio-creds' NOT found in namespace '$NAMESPACE'"
    log_info "This secret is required for PITR backup storage"
    MINIO_SECRET_MISSING=true
    
    # Try to find the secret in other namespaces
    log_info "Searching for 'myminio-creds' in other namespaces..."
    FOUND_NAMESPACES=$(kubectl get secrets --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name=="myminio-creds") | .metadata.namespace' 2>/dev/null || echo "")
    
    if [ -n "$FOUND_NAMESPACES" ]; then
        log_info "Found 'myminio-creds' in namespaces:"
        echo "$FOUND_NAMESPACES" | while read -r ns; do
            echo "  - $ns"
        done
        MINIO_SECRET_SOURCE_NS=$(echo "$FOUND_NAMESPACES" | head -1)
    else
        log_warn "Secret 'myminio-creds' not found in any namespace"
    fi
fi
echo ""

# 6. MinIO Service Check
log_header "6. MinIO Service Check"

MINIO_NS_FOUND=false

# Check for minio-operator namespace (correct for on-prem)
if kubectl get namespace minio-operator &>/dev/null; then
    log_success "MinIO Operator namespace exists"
    MINIO_NS_FOUND=true
    
    # Check for myminio-hl headless service
    if kubectl get service myminio-hl -n minio-operator &>/dev/null; then
        log_success "MinIO headless service 'myminio-hl' exists"
        log_info "Expected endpoint: https://myminio-hl.minio-operator.svc.cluster.local:9000"
    else
        log_error "MinIO headless service 'myminio-hl' not found"
    fi
    
    # Check MinIO pods
    MINIO_PODS=$(kubectl get pods -n minio-operator --no-headers 2>/dev/null | grep myminio || echo "")
    if [ -n "$MINIO_PODS" ]; then
        log_success "MinIO pods found:"
        echo "$MINIO_PODS" | while read -r line; do
            POD_NAME=$(echo "$line" | awk '{print $1}')
            STATUS=$(echo "$line" | awk '{print $3}')
            echo "  - $POD_NAME: $STATUS"
        done
    else
        log_warn "No MinIO pods found with name 'myminio' in minio-operator namespace"
    fi
fi

# Also check legacy minio namespace
if kubectl get namespace minio &>/dev/null; then
    if [ "$MINIO_NS_FOUND" = false ]; then
        log_info "Found 'minio' namespace (legacy location)"
        MINIO_NS_FOUND=true
    else
        log_info "Found both 'minio' and 'minio-operator' namespaces"
    fi
fi

if [ "$MINIO_NS_FOUND" = false ]; then
    log_error "MinIO namespace not found (checked: minio-operator, minio)"
    log_info "MinIO is required for PITR backup storage"
    log_info "You may need to install MinIO Operator first"
fi
echo ""

# 7. PXC Cluster Configuration
log_header "7. PXC Cluster Backup Configuration"
PXC_RESOURCE="${CLUSTER_NAME}-pxc-db"

BACKUP_CONFIG_WRONG=false
GTID_MISSING=false

if kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" &>/dev/null; then
    log_success "PXC resource '$PXC_RESOURCE' exists"
    
    # Check backup configuration
    BACKUP_STORAGE=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages}' 2>/dev/null || echo "")
    if [ -n "$BACKUP_STORAGE" ] && [ "$BACKUP_STORAGE" != "{}" ]; then
        log_success "Backup storage is configured"
        echo ""
        
        # Check MinIO storage configuration specifically
        MINIO_STORAGE_TYPE=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.type}' 2>/dev/null || echo "")
        MINIO_VERIFY_TLS=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.verifyTLS}' 2>/dev/null || echo "")
        MINIO_ENDPOINT=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.s3.endpointUrl}' 2>/dev/null || echo "")
        MINIO_CREDS=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.s3.credentialsSecret}' 2>/dev/null || echo "")
        MINIO_BUCKET=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.storages.minio.s3.bucket}' 2>/dev/null || echo "")
        
        log_info "MinIO storage configuration:"
        log_info "  Type: ${MINIO_STORAGE_TYPE:-<not set>}"
        log_info "  VerifyTLS: ${MINIO_VERIFY_TLS:-<not set>}"
        log_info "  Endpoint: ${MINIO_ENDPOINT:-<not set>}"
        log_info "  Credentials Secret: ${MINIO_CREDS:-<not set>}"
        log_info "  Bucket: ${MINIO_BUCKET:-<not set>}"
        echo ""
        
        # Verify correct configuration
        if [ "$MINIO_STORAGE_TYPE" != "s3" ]; then
            log_error "✗ Storage type should be 's3', got: ${MINIO_STORAGE_TYPE:-<not set>}"
            BACKUP_CONFIG_WRONG=true
        else
            log_success "✓ Storage type is correct: s3"
        fi
        
        if [ "$MINIO_VERIFY_TLS" != "false" ]; then
            log_warn "⚠ VerifyTLS should be 'false' for self-signed certs, got: ${MINIO_VERIFY_TLS:-<not set>}"
            BACKUP_CONFIG_WRONG=true
        else
            log_success "✓ VerifyTLS is correct: false"
        fi
        
        if [ "$MINIO_ENDPOINT" != "https://myminio-hl.minio-operator.svc.cluster.local:9000" ]; then
            log_error "✗ Endpoint should be 'https://myminio-hl.minio-operator.svc.cluster.local:9000', got: ${MINIO_ENDPOINT:-<not set>}"
            BACKUP_CONFIG_WRONG=true
        else
            log_success "✓ Endpoint is correct"
        fi
        
        if [ "$MINIO_CREDS" != "myminio-creds" ]; then
            log_error "✗ Credentials secret should be 'myminio-creds', got: ${MINIO_CREDS:-<not set>}"
            BACKUP_CONFIG_WRONG=true
        else
            log_success "✓ Credentials secret is correct"
        fi
    else
        log_error "Backup storage configuration is empty or not found"
        BACKUP_CONFIG_WRONG=true
    fi
    
    # Check PITR enabled
    PITR_ENABLED=$(kubectl get perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.backup.pitr.enabled}' 2>/dev/null || echo "false")
    if [ "$PITR_ENABLED" = "true" ]; then
        log_success "✓ PITR is enabled in cluster configuration"
    else
        log_error "✗ PITR is NOT enabled in cluster configuration"
        BACKUP_CONFIG_WRONG=true
    fi
    
    # Check GTID_CACHE_KEY again and track for repair
    if [ -z "$GTID_KEY" ]; then
        GTID_MISSING=true
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

# Repair Functions
copy_minio_secret() {
    local source_ns="$1"
    log_info "Copying 'myminio-creds' secret from namespace '$source_ns' to '$NAMESPACE'..."
    
    if kubectl get secret myminio-creds -n "$source_ns" -o yaml 2>/dev/null | \
        sed "s/namespace: $source_ns/namespace: $NAMESPACE/" | \
        grep -v '^\s*resourceVersion:' | \
        grep -v '^\s*uid:' | \
        grep -v '^\s*creationTimestamp:' | \
        kubectl apply -f - 2>/dev/null; then
        log_success "✓ Successfully copied 'myminio-creds' secret"
        return 0
    else
        log_error "✗ Failed to copy secret"
        return 1
    fi
}

add_gtid_key() {
    log_info "Adding GTID_CACHE_KEY to PITR deployment..."
    
    if kubectl patch deployment "$PITR_DEPLOYMENT" -n "$NAMESPACE" --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"GTID_CACHE_KEY","value":"pxc-pitr-cache"}}]' 2>/dev/null; then
        log_success "✓ Successfully added GTID_CACHE_KEY"
        return 0
    else
        log_error "✗ Failed to add GTID_CACHE_KEY"
        return 1
    fi
}

fix_backup_config() {
    log_info "Fixing backup storage configuration..."
    
    # Prompt for MinIO bucket
    echo -n "Enter MinIO bucket name: "
    read -r BUCKET_NAME
    
    if [ -z "$BUCKET_NAME" ]; then
        log_error "Bucket name is required"
        return 1
    fi
    
    # Create patch JSON
    local patch='{
      "spec": {
        "backup": {
          "pitr": {
            "enabled": true
          },
          "storages": {
            "minio": {
              "type": "s3",
              "verifyTLS": false,
              "s3": {
                "bucket": "'$BUCKET_NAME'",
                "region": "us-east-1",
                "credentialsSecret": "myminio-creds",
                "endpointUrl": "https://myminio-hl.minio-operator.svc.cluster.local:9000"
              }
            }
          }
        }
      }
    }'
    
    if kubectl patch perconaxtradbcluster "$PXC_RESOURCE" -n "$NAMESPACE" --type=merge -p "$patch" 2>/dev/null; then
        log_success "✓ Successfully updated backup configuration"
        return 0
    else
        log_error "✗ Failed to update backup configuration"
        return 1
    fi
}

perform_repairs() {
    log_header "PERFORMING REPAIRS"
    local repairs_made=0
    local repairs_failed=0
    
    # 1. Copy MinIO secret if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " copy_minio_secret " ]]; then
        if [ -n "$MINIO_SECRET_SOURCE_NS" ]; then
            echo ""
            log_info "Repair 1/3: Copy MinIO secret"
            echo -n "Copy 'myminio-creds' from namespace '$MINIO_SECRET_SOURCE_NS'? (yes/no) [yes]: "
            read -r COPY_SECRET
            COPY_SECRET=${COPY_SECRET:-yes}
            
            if [[ "$COPY_SECRET" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                if copy_minio_secret "$MINIO_SECRET_SOURCE_NS"; then
                    ((repairs_made++))
                    MINIO_SECRET_MISSING=false
                else
                    ((repairs_failed++))
                fi
            else
                log_info "Skipped"
            fi
        fi
    fi
    
    # 2. Add GTID_CACHE_KEY if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " add_gtid_key " ]]; then
        echo ""
        log_info "Repair 2/3: Add GTID_CACHE_KEY"
        echo -n "Add GTID_CACHE_KEY to PITR deployment? (yes/no) [yes]: "
        read -r ADD_GTID
        ADD_GTID=${ADD_GTID:-yes}
        
        if [[ "$ADD_GTID" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            if add_gtid_key; then
                ((repairs_made++))
                GTID_MISSING=false
            else
                ((repairs_failed++))
            fi
        else
            log_info "Skipped"
        fi
    fi
    
    # 3. Fix backup config if needed
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_backup_config " ]]; then
        echo ""
        log_info "Repair 3/3: Fix backup storage configuration"
        echo -n "Update backup storage configuration? (yes/no) [yes]: "
        read -r FIX_BACKUP
        FIX_BACKUP=${FIX_BACKUP:-yes}
        
        if [[ "$FIX_BACKUP" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            if fix_backup_config; then
                ((repairs_made++))
                BACKUP_CONFIG_WRONG=false
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
    
    # Restart PITR deployment if any repairs were made
    if [ $repairs_made -gt 0 ]; then
        echo ""
        log_info "Restarting PITR deployment to apply changes..."
        
        if kubectl rollout restart deployment "$PITR_DEPLOYMENT" -n "$NAMESPACE" 2>/dev/null; then
            log_success "✓ PITR deployment restarted"
            log_info "Monitor pod status with: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=pitr -w"
        else
            log_error "✗ Failed to restart PITR deployment"
            log_info "Try manually: kubectl rollout restart deployment $PITR_DEPLOYMENT -n $NAMESPACE"
        fi
    fi
}

# Summary and Recommendations
log_header "SUMMARY AND REPAIR OPTIONS"

ISSUES=()
REPAIRS_AVAILABLE=()

# Track issues found
if [ "$MINIO_SECRET_MISSING" = true ]; then
    ISSUES+=("MinIO secret 'myminio-creds' is missing in namespace '$NAMESPACE'")
    if [ -n "$MINIO_SECRET_SOURCE_NS" ]; then
        REPAIRS_AVAILABLE+=("copy_minio_secret")
    fi
fi

if [ "$GTID_MISSING" = true ]; then
    ISSUES+=("GTID_CACHE_KEY environment variable is missing from PITR deployment")
    REPAIRS_AVAILABLE+=("add_gtid_key")
fi

if [ "$BACKUP_CONFIG_WRONG" = true ]; then
    ISSUES+=("Backup storage configuration is incorrect or incomplete")
    REPAIRS_AVAILABLE+=("fix_backup_config")
fi

# Display issues
if [ ${#ISSUES[@]} -eq 0 ]; then
    log_success "✓ No major configuration issues detected"
    log_info "If PITR pod is still failing, check the logs above for specific error messages"
else
    log_warn "Found ${#ISSUES[@]} issue(s):"
    for issue in "${ISSUES[@]}"; do
        echo "  ✗ $issue"
    done
fi

echo ""

# Offer repairs if in fix mode
if [ "$FIX_MODE" = "true" ] && [ ${#REPAIRS_AVAILABLE[@]} -gt 0 ]; then
    log_info "Repair mode is ENABLED. Available fixes:"
    
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " copy_minio_secret " ]]; then
        echo "  1. Copy 'myminio-creds' secret from source namespace"
    fi
    
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " add_gtid_key " ]]; then
        echo "  2. Add GTID_CACHE_KEY to PITR deployment"
    fi
    
    if [[ " ${REPAIRS_AVAILABLE[@]} " =~ " fix_backup_config " ]]; then
        echo "  3. Fix backup storage configuration"
    fi
    
    echo ""
    
    # Prompt to proceed
    echo -n "Would you like to attempt these repairs? (yes/no) [yes]: "
    read -r PROCEED
    PROCEED=${PROCEED:-yes}
    
    if [[ "$PROCEED" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        perform_repairs
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
log_info "Diagnostic complete"
log_info "For more help, check:"
log_info "  - Percona Operator docs: https://docs.percona.com/percona-operator-for-mysql/pxc/"
log_info "  - PITR documentation: https://docs.percona.com/percona-operator-for-mysql/pxc/backups-pitr.html"
echo ""


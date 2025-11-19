#!/bin/bash

# Post-PXC Installation Secret Configuration Script
# This script configures db-secrets after PXC cluster installation by:
# 1. Copying MinIO credentials (for S3-compatible backups)
# 2. Adding PMM server token (for monitoring)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
TARGET_NAMESPACE=""
MINIO_NAMESPACE="minio"
MINIO_SECRET_NAME="minio"
DB_SECRET_NAME="db-secrets"
KUBECONFIG="${KUBECONFIG:-}"

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
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 --target-namespace NAMESPACE

Post-installation configuration script for Percona XtraDB Cluster.

This script updates the db-secrets in the target namespace with:
  1. MinIO credentials (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)
  2. PMM server token (pmmservertoken)

OPTIONS:
    --target-namespace NAMESPACE   Target namespace containing db-secrets (required)
    -h, --help                     Show this help message

PREREQUISITES:
    - db-secrets must already exist in the target namespace
    - minio secret must exist in the minio namespace
    - kubectl must be configured with appropriate permissions

DESCRIPTION:
    This script configures the db-secrets secret after PXC installation by:
    
    1. MinIO Credentials:
       - Reads rootUser from minio/minio secret
       - Reads rootPassword from minio/minio secret
       - Adds AWS_ACCESS_KEY_ID=rootUser to db-secrets
       - Adds AWS_SECRET_ACCESS_KEY=rootPassword to db-secrets
    
    2. PMM Token:
       - Prompts for PMM service account token
       - Base64 encodes the token
       - Adds pmmservertoken to db-secrets
    
    The script patches the existing db-secrets, preserving all other keys.

EXAMPLES:
    # Configure db-secrets in the percona namespace
    $0 --target-namespace percona
    
    # Configure db-secrets in a custom namespace
    $0 --target-namespace my-pxc-cluster

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    if [ $# -eq 0 ]; then
        log_error "No arguments provided"
        usage
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --target-namespace)
                TARGET_NAMESPACE="$2"
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
    
    # Validate required arguments
    if [ -z "$TARGET_NAMESPACE" ]; then
        log_error "Target namespace is required (--target-namespace)"
        usage
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    # Check cluster connection
    if ! kctl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    
    # Check if target namespace exists
    if ! kctl get namespace "$TARGET_NAMESPACE" &> /dev/null; then
        log_error "Target namespace '$TARGET_NAMESPACE' does not exist"
        exit 1
    fi
    
    # Check if db-secrets exists in target namespace
    if ! kctl get secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" &> /dev/null; then
        log_error "Secret '$DB_SECRET_NAME' not found in namespace '$TARGET_NAMESPACE'"
        log_error "The db-secrets secret must exist before running this script."
        log_error "It is typically created by the Percona Operator during cluster creation."
        exit 1
    fi
    
    # Check if minio namespace exists
    if ! kctl get namespace "$MINIO_NAMESPACE" &> /dev/null; then
        log_error "MinIO namespace '$MINIO_NAMESPACE' does not exist"
        log_error "MinIO must be installed before running this script."
        exit 1
    fi
    
    # Check if minio secret exists
    if ! kctl get secret "$MINIO_SECRET_NAME" -n "$MINIO_NAMESPACE" &> /dev/null; then
        log_error "Secret '$MINIO_SECRET_NAME' not found in namespace '$MINIO_NAMESPACE'"
        log_error "MinIO secret is required for S3-compatible backup configuration."
        exit 1
    fi
    
    log_success "Prerequisites met"
    echo ""
}

# Get MinIO credentials
get_minio_credentials() {
    log_step "Retrieving MinIO credentials..."
    
    # Get rootUser from minio secret
    local root_user=$(kctl get secret "$MINIO_SECRET_NAME" -n "$MINIO_NAMESPACE" \
        -o jsonpath='{.data.rootUser}' 2>/dev/null || echo "")
    
    if [ -z "$root_user" ]; then
        log_error "Could not retrieve rootUser from $MINIO_NAMESPACE/$MINIO_SECRET_NAME"
        exit 1
    fi
    
    # Get rootPassword from minio secret
    local root_password=$(kctl get secret "$MINIO_SECRET_NAME" -n "$MINIO_NAMESPACE" \
        -o jsonpath='{.data.rootPassword}' 2>/dev/null || echo "")
    
    if [ -z "$root_password" ]; then
        log_error "Could not retrieve rootPassword from $MINIO_NAMESPACE/$MINIO_SECRET_NAME"
        exit 1
    fi
    
    # Decode and display (masked)
    local root_user_decoded=$(echo "$root_user" | base64 -d 2>/dev/null || echo "")
    local root_password_decoded=$(echo "$root_password" | base64 -d 2>/dev/null || echo "")
    
    if [ -z "$root_user_decoded" ] || [ -z "$root_password_decoded" ]; then
        log_error "Failed to decode MinIO credentials"
        exit 1
    fi
    
    log_success "MinIO credentials retrieved"
    log_info "  Root User: ${root_user_decoded:0:3}***"
    log_info "  Root Password: ***"
    echo ""
    
    # Return base64 encoded values (already base64 encoded from secret)
    echo "$root_user"
    echo "$root_password"
}

# Prompt for PMM token
get_pmm_token() {
    log_step "PMM Service Account Token Configuration"
    echo ""
    log_info "Please enter the PMM service account token."
    log_info "This token is used for PMM (Percona Monitoring and Management) integration."
    echo ""
    
    local pmm_token=""
    
    # Prompt for token
    echo -n "PMM Service Account Token: "
    read -r pmm_token
    
    if [ -z "$pmm_token" ]; then
        log_error "PMM token cannot be empty"
        exit 1
    fi
    
    # Base64 encode the token
    local pmm_token_b64=$(echo -n "$pmm_token" | base64 | tr -d '\n')
    
    if [ -z "$pmm_token_b64" ]; then
        log_error "Failed to base64 encode PMM token"
        exit 1
    fi
    
    log_success "PMM token processed"
    log_info "  Token length: ${#pmm_token} characters"
    echo ""
    
    echo "$pmm_token_b64"
}

# Update db-secrets
update_db_secrets() {
    local aws_access_key_b64="$1"
    local aws_secret_key_b64="$2"
    local pmm_token_b64="$3"
    
    log_step "Updating db-secrets in namespace '$TARGET_NAMESPACE'..."
    
    # Create a temporary JSON patch file
    local patch_file=$(mktemp)
    trap "rm -f '$patch_file'" EXIT
    
    # Build JSON patch to add/update the three keys
    cat > "$patch_file" << EOF
{
  "data": {
    "AWS_ACCESS_KEY_ID": "$aws_access_key_b64",
    "AWS_SECRET_ACCESS_KEY": "$aws_secret_key_b64",
    "pmmservertoken": "$pmm_token_b64"
  }
}
EOF
    
    # Apply the patch (strategic merge patch preserves other keys)
    if kctl patch secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" \
        --type=merge \
        --patch-file="$patch_file" 2>/dev/null; then
        log_success "Successfully updated $DB_SECRET_NAME"
    else
        log_error "Failed to update $DB_SECRET_NAME"
        exit 1
    fi
    
    echo ""
}

# Verify the update
verify_update() {
    log_step "Verifying secret update..."
    
    # Check if all three keys exist
    local has_aws_access=$(kctl get secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null || echo "")
    local has_aws_secret=$(kctl get secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null || echo "")
    local has_pmm_token=$(kctl get secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" \
        -o jsonpath='{.data.pmmservertoken}' 2>/dev/null || echo "")
    
    local success=true
    
    if [ -n "$has_aws_access" ]; then
        log_success "✓ AWS_ACCESS_KEY_ID present in db-secrets"
    else
        log_error "✗ AWS_ACCESS_KEY_ID missing from db-secrets"
        success=false
    fi
    
    if [ -n "$has_aws_secret" ]; then
        log_success "✓ AWS_SECRET_ACCESS_KEY present in db-secrets"
    else
        log_error "✗ AWS_SECRET_ACCESS_KEY missing from db-secrets"
        success=false
    fi
    
    if [ -n "$has_pmm_token" ]; then
        log_success "✓ pmmservertoken present in db-secrets"
    else
        log_error "✗ pmmservertoken missing from db-secrets"
        success=false
    fi
    
    echo ""
    
    if [ "$success" = false ]; then
        log_error "Verification failed!"
        exit 1
    fi
    
    log_success "Verification successful!"
}

# Main execution
main() {
    parse_args "$@"
    
    echo ""
    log_info "=== Post-PXC Installation Configuration ==="
    log_info "Target Namespace: $TARGET_NAMESPACE"
    log_info "MinIO Namespace: $MINIO_NAMESPACE"
    echo ""
    
    check_prerequisites
    
    # Get MinIO credentials
    local minio_creds=$(get_minio_credentials)
    local aws_access_key_b64=$(echo "$minio_creds" | sed -n '1p')
    local aws_secret_key_b64=$(echo "$minio_creds" | sed -n '2p')
    
    # Get PMM token
    local pmm_token_b64=$(get_pmm_token)
    
    # Update db-secrets
    update_db_secrets "$aws_access_key_b64" "$aws_secret_key_b64" "$pmm_token_b64"
    
    # Verify
    verify_update
    
    echo ""
    log_success "=== Configuration Complete ==="
    echo ""
    log_info "Next steps:"
    log_info "  1. The PXC cluster can now use S3-compatible backups via MinIO"
    log_info "  2. PMM monitoring should be configured with the provided token"
    log_info "  3. You may need to restart PXC pods to pick up the new credentials"
    echo ""
    log_info "To restart PXC pods (if needed):"
    log_info "  kubectl rollout restart statefulset -n $TARGET_NAMESPACE"
    echo ""
}

main "$@"


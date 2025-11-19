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
DEBUG=false

# kubectl wrapper function that always includes --kubeconfig if set
kctl() {
    if [ "$DEBUG" = true ]; then
        log_debug "Running: kubectl $*"
    fi
    
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

log_debug() {
    if [ "$DEBUG" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
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
    --debug                        Enable debug output
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
            --debug)
                DEBUG=true
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
    # All logging to stderr so it doesn't interfere with return values
    log_step "Retrieving MinIO credentials..." >&2
    log_debug "Getting secret '$MINIO_SECRET_NAME' from namespace '$MINIO_NAMESPACE'" >&2
    
    # Get rootUser from minio secret (base64 encoded)
    log_debug "Extracting rootUser from secret..." >&2
    local root_user=$(kctl get secret "$MINIO_SECRET_NAME" -n "$MINIO_NAMESPACE" \
        -o jsonpath='{.data.rootUser}' 2>/dev/null || echo "")
    
    # Clean the value (remove whitespace, newlines, carriage returns)
    root_user=$(echo "$root_user" | tr -d '\n\r\t ' || echo "")
    
    if [ -z "$root_user" ]; then
        log_error "Could not retrieve rootUser from $MINIO_NAMESPACE/$MINIO_SECRET_NAME" >&2
        log_debug "Command that failed: kctl get secret $MINIO_SECRET_NAME -n $MINIO_NAMESPACE -o jsonpath='{.data.rootUser}'" >&2
        exit 1
    fi
    log_debug "rootUser retrieved (base64 length: ${#root_user})" >&2
    
    # Get rootPassword from minio secret (base64 encoded)
    log_debug "Extracting rootPassword from secret..." >&2
    local root_password=$(kctl get secret "$MINIO_SECRET_NAME" -n "$MINIO_NAMESPACE" \
        -o jsonpath='{.data.rootPassword}' 2>/dev/null || echo "")
    
    # Clean the value (remove whitespace, newlines, carriage returns)
    root_password=$(echo "$root_password" | tr -d '\n\r\t ' || echo "")
    
    if [ -z "$root_password" ]; then
        log_error "Could not retrieve rootPassword from $MINIO_NAMESPACE/$MINIO_SECRET_NAME" >&2
        log_debug "Command that failed: kctl get secret $MINIO_SECRET_NAME -n $MINIO_NAMESPACE -o jsonpath='{.data.rootPassword}'" >&2
        exit 1
    fi
    log_debug "rootPassword retrieved (base64 length: ${#root_password})" >&2
    
    # Decode and display (masked) - for verification only
    log_debug "Decoding base64 values for verification..." >&2
    local root_user_decoded=""
    local root_password_decoded=""
    
    # Handle both Linux and macOS base64 decode
    if echo "$root_user" | base64 -d &>/dev/null 2>&1; then
        # Linux base64
        root_user_decoded=$(echo "$root_user" | base64 -d 2>/dev/null || echo "")
        root_password_decoded=$(echo "$root_password" | base64 -d 2>/dev/null || echo "")
    else
        # macOS/BSD base64
        root_user_decoded=$(echo "$root_user" | base64 -D 2>/dev/null || echo "")
        root_password_decoded=$(echo "$root_password" | base64 -D 2>/dev/null || echo "")
    fi
    
    if [ -z "$root_user_decoded" ] || [ -z "$root_password_decoded" ]; then
        log_error "Failed to decode MinIO credentials for verification" >&2
        log_debug "root_user_decoded length: ${#root_user_decoded}" >&2
        log_debug "root_password_decoded length: ${#root_password_decoded}" >&2
        exit 1
    fi
    
    log_success "MinIO credentials retrieved" >&2
    log_info "  Root User: ${root_user_decoded:0:3}***" >&2
    log_info "  Root Password: ***" >&2
    log_debug "Decoded user: $root_user_decoded" >&2
    log_debug "Decoded password length: ${#root_password_decoded}" >&2
    echo "" >&2
    
    # Return ONLY the base64 encoded values to stdout (for capture)
    log_debug "Returning base64 encoded credentials (cleaned)" >&2
    log_debug "About to echo root_user (length: ${#root_user})" >&2
    log_debug "About to echo root_password (length: ${#root_password})" >&2
    
    # Explicitly write to stdout (fd 1)
    echo "$root_user" >&1
    echo "$root_password" >&1
}

# Prompt for PMM token
get_pmm_token() {
    # All logging/output to stderr so it doesn't interfere with function return value
    log_step "PMM Service Account Token Configuration" >&2
    echo "" >&2
    log_info "Please enter the PMM service account token." >&2
    log_info "This token is used for PMM (Percona Monitoring and Management) integration." >&2
    echo "" >&2
    
    local pmm_token=""
    
    # Prompt for token (everything to stderr, read from /dev/tty for WSL)
    log_debug "Waiting for user input (PMM token)..." >&2
    
    # Print prompt to /dev/tty to ensure it's visible
    if [ -w /dev/tty ]; then
        echo -n "PMM Service Account Token: " > /dev/tty
    else
        echo -n "PMM Service Account Token: " >&2
    fi
    
    # Try multiple methods to read input (WSL compatibility)
    if [ -r /dev/tty ]; then
        # Best method: read directly from /dev/tty
        log_debug "Reading from /dev/tty" >&2
        read -r pmm_token < /dev/tty
    elif [ -t 0 ]; then
        # stdin is a terminal
        log_debug "Reading from stdin (terminal)" >&2
        read -r pmm_token
    else
        # Last resort: try stdin anyway
        log_debug "Reading from stdin (not a terminal)" >&2
        read -r pmm_token
    fi
    
    log_debug "User input received (length: ${#pmm_token})" >&2
    
    if [ -z "$pmm_token" ]; then
        log_error "PMM token cannot be empty" >&2
        exit 1
    fi
    
    # Base64 encode the token (handle both Linux and macOS base64)
    log_debug "Encoding PMM token to base64..." >&2
    local pmm_token_b64=""
    if echo -n "$pmm_token" | base64 -w 0 &>/dev/null 2>&1; then
        # Linux base64 (with -w 0 for no line wrapping)
        pmm_token_b64=$(echo -n "$pmm_token" | base64 -w 0)
    else
        # macOS/BSD base64 (no line wrapping by default)
        pmm_token_b64=$(echo -n "$pmm_token" | base64)
    fi
    
    # Strip any newlines/whitespace just in case
    pmm_token_b64=$(echo -n "$pmm_token_b64" | tr -d '\n\r ')
    
    if [ -z "$pmm_token_b64" ]; then
        log_error "Failed to base64 encode PMM token" >&2
        log_debug "base64 command may have failed" >&2
        exit 1
    fi
    log_debug "PMM token encoded (base64 length: ${#pmm_token_b64})" >&2
    
    log_success "PMM token processed" >&2
    log_info "  Token length: ${#pmm_token} characters" >&2
    echo "" >&2
    
    log_debug "Returning encoded PMM token" >&2
    
    # ONLY the base64 token goes to stdout (for capture)
    echo "$pmm_token_b64"
}

# Update db-secrets
update_db_secrets() {
    local aws_access_key_b64="$1"
    local aws_secret_key_b64="$2"
    local pmm_token_b64="$3"
    
    log_step "Updating db-secrets in namespace '$TARGET_NAMESPACE'..."
    log_debug "AWS_ACCESS_KEY_ID length: ${#aws_access_key_b64}"
    log_debug "AWS_SECRET_ACCESS_KEY length: ${#aws_secret_key_b64}"
    log_debug "pmmservertoken length: ${#pmm_token_b64}"
    
    # Create a temporary JSON patch file
    log_debug "Creating temporary patch file..."
    local patch_file=$(mktemp)
    trap "rm -f '$patch_file'" EXIT
    log_debug "Temp patch file: $patch_file"
    
    # Build JSON patch to add/update the three keys
    log_debug "Writing JSON patch using jq for proper escaping..."
    
    # Use jq to build JSON properly (handles special characters and escaping)
    if command -v jq &> /dev/null; then
        log_debug "Using jq to build JSON patch"
        jq -n \
            --arg access_key "$aws_access_key_b64" \
            --arg secret_key "$aws_secret_key_b64" \
            --arg pmm_token "$pmm_token_b64" \
            '{data: {AWS_ACCESS_KEY_ID: $access_key, AWS_SECRET_ACCESS_KEY: $secret_key, pmmservertoken: $pmm_token}}' \
            > "$patch_file"
    else
        # Fallback: manual JSON construction with escaped values
        log_debug "jq not available, using manual JSON construction"
        # Escape any backslashes and double quotes in the base64 strings
        local escaped_access=$(echo "$aws_access_key_b64" | sed 's/\\/\\\\/g; s/"/\\"/g')
        local escaped_secret=$(echo "$aws_secret_key_b64" | sed 's/\\/\\\\/g; s/"/\\"/g')
        local escaped_pmm=$(echo "$pmm_token_b64" | sed 's/\\/\\\\/g; s/"/\\"/g')
        
        cat > "$patch_file" << EOF
{
  "data": {
    "AWS_ACCESS_KEY_ID": "$escaped_access",
    "AWS_SECRET_ACCESS_KEY": "$escaped_secret",
    "pmmservertoken": "$escaped_pmm"
  }
}
EOF
    fi
    
    if [ "$DEBUG" = true ]; then
        log_debug "Patch file contents:"
        cat "$patch_file" | head -20 # Show first 20 lines
    fi
    
    # Apply the patch (strategic merge patch preserves other keys)
    log_debug "Applying patch to secret '$DB_SECRET_NAME' in namespace '$TARGET_NAMESPACE'..."
    if kctl patch secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" \
        --type=merge \
        --patch-file="$patch_file" 2>/dev/null; then
        log_success "Successfully updated $DB_SECRET_NAME"
    else
        log_error "Failed to update $DB_SECRET_NAME"
        log_debug "Patch command failed. Trying with verbose output..."
        kctl patch secret "$DB_SECRET_NAME" -n "$TARGET_NAMESPACE" \
            --type=merge \
            --patch-file="$patch_file"
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
    log_debug "Starting script execution..."
    log_debug "Arguments: $*"
    
    parse_args "$@"
    
    log_debug "DEBUG mode: $DEBUG"
    log_debug "TARGET_NAMESPACE: $TARGET_NAMESPACE"
    log_debug "KUBECONFIG: ${KUBECONFIG:-<not set>}"
    
    echo ""
    log_info "=== Post-PXC Installation Configuration ==="
    log_info "Target Namespace: $TARGET_NAMESPACE"
    log_info "MinIO Namespace: $MINIO_NAMESPACE"
    if [ "$DEBUG" = true ]; then
        log_info "Debug Mode: ENABLED"
    fi
    echo ""
    
    check_prerequisites
    
    # Get MinIO credentials
    log_debug "Calling get_minio_credentials..."
    local minio_creds=$(get_minio_credentials)
    log_debug "get_minio_credentials returned. Processing output..."
    
    if [ "$DEBUG" = true ]; then
        log_debug "Raw minio_creds output:"
        echo "$minio_creds" | od -c >&2
        log_debug "Line count: $(echo "$minio_creds" | wc -l)"
        log_debug "First line: $(echo "$minio_creds" | sed -n '1p')"
        log_debug "Second line: $(echo "$minio_creds" | sed -n '2p')"
    fi
    
    local aws_access_key_b64=$(echo "$minio_creds" | sed -n '1p' | tr -d '\n\r ')
    local aws_secret_key_b64=$(echo "$minio_creds" | sed -n '2p' | tr -d '\n\r ')
    
    log_debug "Extracted AWS_ACCESS_KEY_ID (length: ${#aws_access_key_b64})"
    log_debug "Extracted AWS_SECRET_ACCESS_KEY (length: ${#aws_secret_key_b64})"
    
    if [ -z "$aws_access_key_b64" ] || [ -z "$aws_secret_key_b64" ]; then
        log_error "Failed to extract MinIO credentials from function output"
        log_error "AWS_ACCESS_KEY_ID length: ${#aws_access_key_b64}"
        log_error "AWS_SECRET_ACCESS_KEY length: ${#aws_secret_key_b64}"
        exit 1
    fi
    
    # Get PMM token
    log_debug "Calling get_pmm_token..."
    local pmm_token_b64=$(get_pmm_token)
    log_debug "get_pmm_token returned (length: ${#pmm_token_b64})"
    
    # Update db-secrets
    log_debug "Calling update_db_secrets..."
    update_db_secrets "$aws_access_key_b64" "$aws_secret_key_b64" "$pmm_token_b64"
    log_debug "update_db_secrets completed"
    
    # Verify
    log_debug "Calling verify_update..."
    verify_update
    log_debug "verify_update completed"
    
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
    
    log_debug "Script completed successfully"
}

main "$@"


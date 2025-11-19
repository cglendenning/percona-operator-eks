#!/bin/bash

# Sync MySQL passwords with Kubernetes secrets after restore
# This script updates MySQL user passwords to match the secrets in the cluster
#
# BACKGROUND:
# -----------
# After restoring a Percona XtraDB Cluster from backup, the database may contain
# user passwords that differ from those in the Kubernetes secrets. This causes
# the Percona Operator to fail with errors like:
#
#   "manage sys users: is old password discarded: select User_attributes field: 
#    Access denied for user 'operator'@'x.x.x.x'"
#
# This error occurs because:
# 1. MySQL 8.0+ supports "dual passwords" via RETAIN CURRENT PASSWORD feature
# 2. The User_attributes field (JSON column) stores old password hashes
# 3. The Percona Operator checks this field to verify password state
# 4. The operator user doesn't have permission to read mysql.user table
#
# SOLUTION:
# ---------
# This script uses root credentials to:
# 1. Update all user passwords to match the Kubernetes secret
# 2. Use "DISCARD OLD PASSWORD" to clean the User_attributes field
# 3. This removes any retained old passwords from MySQL 8.0 dual password feature
#
# Starting with Percona Operator v1.18.0, this is handled automatically post-restore.
# For earlier versions, this script provides a manual solution.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
NAMESPACE=""
SECRET_NAME=""
DRY_RUN=false
CLUSTER_NAME=""

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

log_dry_run() {
    echo -e "${BLUE}[DRY-RUN]${NC} $1"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Sync MySQL user passwords with Kubernetes secrets after a restore operation.

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (required)
    -s, --secret SECRET_NAME     Secret name containing passwords (required)
    -c, --cluster CLUSTER_NAME   PXC cluster name (required)
    --dry-run                    Show what would be changed without making changes
    -h, --help                   Show this help message

DESCRIPTION:
    This script synchronizes MySQL user passwords with the passwords stored in the
    Kubernetes secret. It's useful after a restore operation when database accounts
    don't match the current secrets.
    
    The script will:
    1. Read passwords from the specified Kubernetes secret
    2. Query MySQL for all users matching the secret keys (root, operator, monitor, etc.)
    3. Check User_attributes field for retained old passwords (MySQL 8.0 dual password)
    4. Update each user's password to match the secret using DISCARD OLD PASSWORD
    5. This clears the User_attributes field preventing operator authentication errors
    
    Common user accounts: root, operator, monitor, xtrabackup, proxyadmin, replication
    
    NOTE: This fixes the Percona Operator error:
          "manage sys users: is old password discarded: select User_attributes field"

EXAMPLES:
    # Dry-run to see what would change
    $0 -n percona -s pxc-cluster-secrets -c pxc-cluster --dry-run
    
    # Actually sync passwords
    $0 -n percona -s pxc-cluster-secrets -c pxc-cluster

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
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
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
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
    if [ -z "$NAMESPACE" ]; then
        log_error "Namespace is required (-n or --namespace)"
        usage
    fi
    
    if [ -z "$SECRET_NAME" ]; then
        log_error "Secret name is required (-s or --secret)"
        usage
    fi
    
    if [ -z "$CLUSTER_NAME" ]; then
        log_error "Cluster name is required (-c or --cluster)"
        usage
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist"
        exit 1
    fi
    
    # Check if secret exists
    if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_error "Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"
        exit 1
    fi
    
    log_success "Prerequisites met"
}

# Get password from secret
get_secret_password() {
    local username="$1"
    local password=""
    
    # Try common password key patterns
    for key in "$username" "${username}Password" "${username}_password" "${username}Pwd"; do
        password=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.$key}" 2>/dev/null || echo "")
        
        if [ -n "$password" ]; then
            # Decode base64
            password=$(echo "$password" | base64 -d 2>/dev/null || echo "")
            if [ -n "$password" ]; then
                echo "$password"
                return 0
            fi
        fi
    done
    
    return 1
}

# Get list of MySQL users that match a username (different hosts)
get_mysql_users() {
    local base_username="$1"
    local pod_name="$2"
    local root_password="$3"
    
    # Query MySQL for all users matching the base username
    kubectl exec -n "$NAMESPACE" "$pod_name" -c pxc -- \
        mysql -uroot -p"$root_password" -e \
        "SELECT CONCAT(\"'\", user, \"'@'\", host, \"'\") FROM mysql.user WHERE user='$base_username';" \
        -sN 2>/dev/null || echo ""
}

# Check if user has retained (old) passwords in User_attributes
check_user_attributes() {
    local user_host="$1"
    local pod_name="$2"
    local root_password="$3"
    
    # Extract username and host from 'username'@'host' format
    local username=$(echo "$user_host" | sed "s/'//g" | cut -d'@' -f1)
    local host=$(echo "$user_host" | sed "s/'//g" | cut -d'@' -f2)
    
    # Query User_attributes field to check for additional_password (retained old password)
    # The User_attributes field is a JSON column in MySQL 8.0+
    local has_old_password=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c pxc -- \
        mysql -uroot -p"$root_password" -sN -e \
        "SELECT IF(User_attributes LIKE '%additional_password%', 'YES', 'NO') 
         FROM mysql.user 
         WHERE User='$username' AND Host='$host';" \
        2>/dev/null || echo "UNKNOWN")
    
    echo "$has_old_password"
}

# Update MySQL password
update_mysql_password() {
    local user_host="$1"  # Format: 'username'@'host'
    local new_password="$2"
    local pod_name="$3"
    local root_password="$4"
    
    # MySQL 8.0+ supports dual passwords via RETAIN CURRENT PASSWORD
    # When restoring from backup, the User_attributes field may contain
    # old password hashes that need to be discarded.
    # 
    # We use ALTER USER with DISCARD OLD PASSWORD to clean up any
    # retained passwords from the User_attributes JSON field.
    
    kubectl exec -n "$NAMESPACE" "$pod_name" -c pxc -- \
        mysql -uroot -p"$root_password" -e \
        "ALTER USER $user_host IDENTIFIED BY '$new_password' DISCARD OLD PASSWORD; FLUSH PRIVILEGES;" \
        2>/dev/null
}

# Main sync function
sync_passwords() {
    log_info "Starting password synchronization..."
    echo ""
    
    # Find a running PXC pod
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=pxc,app.kubernetes.io/instance=$CLUSTER_NAME" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')
    
    if [ -z "$pod_name" ]; then
        log_error "No running PXC pods found in namespace '$NAMESPACE' for cluster '$CLUSTER_NAME'"
        exit 1
    fi
    
    log_info "Using pod: $pod_name"
    echo ""
    
    # Get root password first
    log_info "Retrieving root password from secret..."
    local root_password=$(get_secret_password "root")
    
    if [ -z "$root_password" ]; then
        log_error "Could not retrieve root password from secret '$SECRET_NAME'"
        exit 1
    fi
    
    log_success "Root password retrieved"
    echo ""
    
    # Test MySQL connection
    log_info "Testing MySQL connection..."
    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -c pxc -- \
        mysql -uroot -p"$root_password" -e "SELECT 1;" &> /dev/null; then
        log_error "Cannot connect to MySQL with root password from secret"
        log_error "The secret may not match the current database state"
        exit 1
    fi
    
    log_success "MySQL connection successful"
    echo ""
    
    # Get all keys from secret
    log_info "Reading secret keys..."
    local secret_keys=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data}' | \
        grep -o '"[^"]*"' | tr -d '"' | grep -v "^$")
    
    if [ -z "$secret_keys" ]; then
        log_error "No keys found in secret '$SECRET_NAME'"
        exit 1
    fi
    
    # Common user account names to look for
    local user_accounts=("root" "operator" "monitor" "xtrabackup" "proxyadmin" "replication" "clustercheck")
    
    local total_updated=0
    local total_skipped=0
    
    if [ "$DRY_RUN" = true ]; then
        log_info "=== DRY-RUN MODE ==="
        log_info "Showing what would be changed without making actual changes"
        echo ""
    fi
    
    # Process each user account
    for username in "${user_accounts[@]}"; do
        # Check if password exists in secret
        local password=$(get_secret_password "$username")
        
        if [ -z "$password" ]; then
            continue  # Skip users not in secret
        fi
        
        log_info "Processing user: $username"
        
        # Get all MySQL users matching this username
        local mysql_users=$(get_mysql_users "$username" "$pod_name" "$root_password")
        
        if [ -z "$mysql_users" ]; then
            log_warn "  No MySQL users found for '$username'"
            ((total_skipped++))
            echo ""
            continue
        fi
        
        # Process each user@host combination
        while IFS= read -r user_host; do
            if [ -z "$user_host" ]; then
                continue
            fi
            
            log_info "  Found: $user_host"
            
            # Check if user has old passwords retained in User_attributes
            local has_old_pwd=$(check_user_attributes "$user_host" "$pod_name" "$root_password")
            if [ "$has_old_pwd" = "YES" ]; then
                log_warn "    ⚠ User has retained old password in User_attributes (will be discarded)"
            fi
            
            if [ "$DRY_RUN" = true ]; then
                if [ "$has_old_pwd" = "YES" ]; then
                    log_dry_run "  Would update password for $user_host AND discard old password"
                else
                    log_dry_run "  Would update password for $user_host"
                fi
                ((total_updated++))
            else
                # Prompt for confirmation
                echo -n "  Update password for $user_host? [y/N]: "
                read -r response
                
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if update_mysql_password "$user_host" "$password" "$pod_name" "$root_password"; then
                        if [ "$has_old_pwd" = "YES" ]; then
                            log_success "  ✓ Password updated and old password discarded for $user_host"
                        else
                            log_success "  ✓ Password updated for $user_host"
                        fi
                        ((total_updated++))
                    else
                        log_error "  ✗ Failed to update password for $user_host"
                        ((total_skipped++))
                    fi
                else
                    log_info "  Skipped $user_host"
                    ((total_skipped++))
                fi
            fi
        done <<< "$mysql_users"
        
        echo ""
    done
    
    # Summary
    echo ""
    log_info "=== SUMMARY ==="
    if [ "$DRY_RUN" = true ]; then
        log_info "Users that would be updated: $total_updated"
        log_info "Users that would be skipped: $total_skipped"
        echo ""
        log_info "Run without --dry-run to apply changes"
    else
        log_success "Users updated: $total_updated"
        log_info "Users skipped: $total_skipped"
    fi
    echo ""
}

# Main execution
main() {
    parse_args "$@"
    
    log_info "MySQL Password Sync Utility"
    log_info "Namespace: $NAMESPACE"
    log_info "Secret: $SECRET_NAME"
    log_info "Cluster: $CLUSTER_NAME"
    if [ "$DRY_RUN" = true ]; then
        log_info "Mode: DRY-RUN"
    fi
    echo ""
    
    check_prerequisites
    sync_passwords
    
    log_success "Password synchronization complete!"
}

main "$@"


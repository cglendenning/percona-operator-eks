#!/bin/bash

# Standalone EBS Volume Cleanup Script for Percona EKS Cluster
# This script only cleans up orphaned EBS volumes without touching the cluster

set -e

# Configuration
REGION="us-east-1"
CLUSTER_NAME="percona-eks"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if AWS credentials are configured and valid
check_aws_credentials() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        log_error "Install it: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
        log_error "AWS credentials are not configured or have expired"
        echo ""
        echo "Please authenticate with AWS first:"
        echo "  aws sso login --profile <profile-name>"
        echo "  export AWS_PROFILE=<profile-name>"
        echo ""
        exit 1
    fi
    
    local identity=$(aws sts get-caller-identity --region "$REGION" 2>/dev/null)
    local account=$(echo "$identity" | jq -r '.Account' 2>/dev/null || echo "Unknown")
    
    log_info "✓ AWS credentials valid (Account: $account, Region: $REGION)"
    echo ""
}

# Find all EBS volumes that belong to the Percona EKS cluster
find_percona_volumes() {
    log_info "Searching for EBS volumes from Percona EKS cluster in $REGION..."
    
    # Method 1: Find by Kubernetes cluster tag
    local tagged_volumes=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
        --query 'Volumes[*].[VolumeId,Size,State,CreateTime,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' \
        --output text 2>/dev/null)
    
    # Method 2: Find by name pattern (for orphaned volumes)
    local named_volumes=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=percona-eks-*,pvc-*" \
        --query 'Volumes[*].[VolumeId,Size,State,CreateTime,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    
    # Method 3: Find available (unattached) volumes with dynamic-pvc pattern
    local dynamic_volumes=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=*dynamic-pvc*" "Name=status,Values=available" \
        --query 'Volumes[*].[VolumeId,Size,State,CreateTime,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    
    # Combine all methods and deduplicate
    {
        echo "$tagged_volumes"
        echo "$named_volumes"
        echo "$dynamic_volumes"
    } | grep -v '^$' | sort -u
}

# Display volumes in a nice table
display_volumes() {
    local volumes="$1"
    
    # Get unique volumes
    local unique_volumes=$(echo "$volumes" | awk '{print $1, $2, $3, $4}' | sort -u)
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                         ORPHANED EBS VOLUMES                                   ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Display each unique volume with its PVCs
    echo "$unique_volumes" | while IFS=$'\t' read -r vol_id size state created_time; do
        # Get all PVC names for this volume
        local pvc_names=$(echo "$volumes" | awk -v vid="$vol_id" '$1 == vid {print $5}' | grep -v '^$' | sort -u)
        
        # Format date
        local created_date=$(date -d "$created_time" "+%Y-%m-%d %H:%M" 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$created_time" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$created_time")
        
        # Display volume header (80 chars total width)
        printf "┌─ %-26s %4sGB  %-10s  %-30s\n" "$vol_id" "$size" "$state" "$created_date"
        
        # Display PVCs indented
        if [ -n "$pvc_names" ]; then
            echo "$pvc_names" | while read -r pvc; do
                # Truncate long names to fit in 75 chars
                if [ ${#pvc} -gt 72 ]; then
                    pvc="${pvc:0:69}..."
                fi
                printf "│  └─ PVC: %-72s\n" "$pvc"
            done
        else
            printf "│  └─ %-77s\n" "(no PVC name)"
        fi
        echo "│"
    done
    echo ""
}

# Calculate and display cost information
show_cost_estimate() {
    local volumes="$1"
    
    # Get unique volumes only for cost calculation
    local unique_volumes=$(echo "$volumes" | awk '{print $1, $2}' | sort -u)
    local volume_count=$(echo "$unique_volumes" | wc -l)
    
    local total_size=$(echo "$unique_volumes" | awk '{sum+=$2} END {print sum}')
    local monthly_cost=$(echo "scale=2; $total_size * 0.08" | bc 2>/dev/null || echo "N/A")
    local yearly_cost=$(echo "scale=2; $monthly_cost * 12" | bc 2>/dev/null || echo "N/A")
    
    echo "┌─────────────────────────────────────┐"
    echo "│         COST ANALYSIS               │"
    echo "├─────────────────────────────────────┤"
    printf "│ Total volumes:     %4d            │\n" "$volume_count"
    printf "│ Total size:        %6sGB         │\n" "$total_size"
    printf "│ Monthly cost:      \$%6s/month   │\n" "$monthly_cost"
    printf "│ Yearly cost:       \$%7s/year   │\n" "$yearly_cost"
    echo "└─────────────────────────────────────┘"
    echo ""
    log_warn "These volumes are costing you money right now!"
}

# Delete volumes with progress
delete_volumes() {
    local volumes="$1"
    
    # Get unique volumes only
    local unique_volumes=$(echo "$volumes" | awk '{print $1, $2}' | sort -u)
    
    log_info "Starting volume deletion..."
    echo ""
    
    local total=$(echo "$unique_volumes" | wc -l)
    local count=0
    local success=0
    local failed=0
    
    echo "$unique_volumes" | while read -r vol_id size; do
        count=$((count + 1))
        local pvc_name=$(echo "$volumes" | awk -v vid="$vol_id" '$1 == vid {print $5; exit}')
        printf "[%2d/%2d] Deleting %s (%sGB) ... " "$count" "$total" "$vol_id" "$size"
        
        if aws ec2 delete-volume --volume-id "$vol_id" --region "$REGION" 2>/dev/null; then
            echo -e "${GREEN}✓ Success${NC}"
            success=$((success + 1))
        else
            echo -e "${RED}✗ Failed${NC}"
            failed=$((failed + 1))
            log_error "       Failed to delete $vol_id (may be attached or in use)"
        fi
    done
    
    echo ""
    log_info "Deletion complete: $success succeeded, $failed failed"
}

# Main execution
main() {
    log_info "╔════════════════════════════════════════════════════════════╗"
    log_info "║    Percona EKS Cluster - EBS Volume Cleanup Tool          ║"
    log_info "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Check AWS credentials first
    check_aws_credentials
    
    # Find volumes
    volumes=$(find_percona_volumes)
    
    if [ -z "$volumes" ]; then
        log_info "✓ No orphaned EBS volumes found for Percona EKS cluster"
        log_info "  Your cleanup is complete!"
        exit 0
    fi
    
    # Count unique volumes only
    local unique_count=$(echo "$volumes" | awk '{print $1}' | sort -u | wc -l)
    log_warn "Found $unique_count distinct orphaned EBS volume(s)"
    
    # Display volumes
    display_volumes "$volumes"
    
    # Show cost estimate
    show_cost_estimate "$volumes"
    
    # Confirm deletion
    log_warn "⚠️  WARNING: This will permanently delete these volumes!"
    log_warn "⚠️  Make sure they are not needed before proceeding."
    echo ""
    read -p "Do you want to delete these volumes? Type 'yes' to confirm: " -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Operation cancelled - no volumes were deleted"
        exit 0
    fi
    
    # Double confirmation for large deletions
    if [ "$volume_count" -gt 10 ]; then
        log_warn "You are about to delete $volume_count volumes!"
        read -p "Are you REALLY sure? Type 'DELETE' to confirm: " -r
        echo ""
        
        if [[ ! $REPLY == "DELETE" ]]; then
            log_info "Operation cancelled - no volumes were deleted"
            exit 0
        fi
    fi
    
    # Delete volumes
    delete_volumes "$volumes"
    
    echo ""
    log_info "✓ Volume cleanup completed!"
    log_info "  Recommendation: Check AWS Console to verify all volumes are deleted"
    log_info "  AWS Console: https://console.aws.amazon.com/ec2/v2/home?region=$REGION#Volumes:"
}

# Check for required tools
check_requirements() {
    if ! command -v bc &> /dev/null; then
        log_warn "bc is not installed (cost calculations will be skipped)"
        log_warn "Install: sudo apt install bc (Ubuntu) or brew install bc (macOS)"
        echo ""
    fi
}

# Run checks and main
check_requirements
main "$@"


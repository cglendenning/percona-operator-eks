#!/bin/bash

# EKS Cluster Cleanup Script
set -e

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Check if running under WSL
        if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# Configuration
STACK_NAME="percona-eks-cluster"
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
    log_info "Checking AWS credentials..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        log_error "Install it: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    # Try to get caller identity
    if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
        log_error "AWS credentials are not configured or have expired"
        echo ""
        echo "Please authenticate with AWS first:"
        echo ""
        echo "Option 1: AWS SSO"
        echo "  aws sso login --profile <profile-name>"
        echo "  export AWS_PROFILE=<profile-name>"
        echo ""
        echo "Option 2: AWS Configure"
        echo "  aws configure"
        echo ""
        echo "Option 3: Environment Variables"
        echo "  export AWS_ACCESS_KEY_ID=<key>"
        echo "  export AWS_SECRET_ACCESS_KEY=<secret>"
        echo ""
        exit 1
    fi
    
    # Get and display current identity
    local identity=$(aws sts get-caller-identity --region "$REGION" 2>/dev/null)
    local account=$(echo "$identity" | jq -r '.Account' 2>/dev/null || echo "Unknown")
    local arn=$(echo "$identity" | jq -r '.Arn' 2>/dev/null || echo "Unknown")
    
    log_info "✓ AWS credentials valid"
    echo "  Account: $account"
    echo "  Identity: $arn"
    echo "  Region: $REGION"
    echo ""
}

# Find EBS volumes created by the EKS cluster
find_cluster_volumes() {
    # Note: Don't output log messages here as this function's output is captured
    
    # Find volumes by cluster tag
    local volumes=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
        --query 'Volumes[*].[VolumeId,Size,State,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' \
        --output text 2>/dev/null)
    
    # Also find volumes by name pattern (for orphaned volumes that may have lost tags)
    local orphaned_volumes=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=percona-eks-*" "Name=status,Values=available" \
        --query 'Volumes[*].[VolumeId,Size,State,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    
    # Combine and deduplicate
    echo "$volumes"$'\n'"$orphaned_volumes" | sort -u | grep -v '^$'
}

# Delete EBS volumes
delete_volumes() {
    log_info "Searching for EBS volumes created by cluster: $CLUSTER_NAME"
    
    local volumes=$(find_cluster_volumes)
    
    if [ -z "$volumes" ]; then
        log_info "No EBS volumes found for cluster $CLUSTER_NAME"
        return 0
    fi
    
    # Get unique volume IDs and their details
    local unique_volumes=$(echo "$volumes" | awk '{print $1, $2, $3}' | sort -u)
    local volume_count=$(echo "$unique_volumes" | wc -l)
    
    log_warn "Found $volume_count distinct EBS volume(s) from cluster $CLUSTER_NAME:"
    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    
    # Display each unique volume with its PVCs
    echo "$unique_volumes" | while read -r vol_id size state; do
        # Get all PVC names for this volume
        local pvc_names=$(echo "$volumes" | awk -v vid="$vol_id" '$1 == vid {print $4}' | grep -v '^$' | sort -u)
        
        # Display volume header
        printf "│ %-26s %6s  %-32s│\n" "$vol_id" "${size}GB" "$state"
        
        # Display PVCs indented
        if [ -n "$pvc_names" ]; then
            echo "$pvc_names" | while read -r pvc; do
                printf "│   └─ %-62s│\n" "$pvc"
            done
        else
            printf "│   └─ %-62s│\n" "(no PVC name)"
        fi
        echo "│                                                                    │"
    done
    
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Calculate cost estimate (gp3 pricing ~$0.08/GB/month) - ONCE per volume
    local total_size=$(echo "$unique_volumes" | awk '{sum+=$2} END {print sum}')
    local monthly_cost=$(echo "scale=2; $total_size * 0.08" | bc 2>/dev/null || echo "N/A")
    local yearly_cost=$(echo "scale=2; $monthly_cost * 12" | bc 2>/dev/null || echo "N/A")
    
    echo "┌─────────────────────────────────────┐"
    echo "│         COST ANALYSIS               │"
    echo "├─────────────────────────────────────┤"
    printf "│ Total volumes:     %4d             │\n" "$volume_count"
    printf "│ Total size:        %6sGB         │\n" "$total_size"
    printf "│ Monthly cost:      \$%6s/month    │\n" "$monthly_cost"
    printf "│ Yearly cost:       \$%7s/year    │\n" "$yearly_cost"
    echo "└─────────────────────────────────────┘"
    echo ""
    
    read -p "Do you want to delete these volumes? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping volume deletion"
        return 0
    fi
    
    log_info "Deleting EBS volumes..."
    
    local deleted=0
    local failed=0
    
    echo "$unique_volumes" | while read -r vol_id size state; do
        local pvc_name=$(echo "$volumes" | awk -v vid="$vol_id" '$1 == vid {print $4; exit}')
        log_info "Deleting volume: $vol_id (${size}GB, ${pvc_name:-orphaned})"
        
        if aws ec2 delete-volume --volume-id "$vol_id" --region "$REGION" 2>/dev/null; then
            log_info "✓ Deleted: $vol_id"
            deleted=$((deleted + 1))
        else
            log_error "✗ Failed to delete: $vol_id (may be attached or in use)"
            failed=$((failed + 1))
        fi
    done
    
    log_info "Volume cleanup completed: $deleted deleted, $failed failed"
}

# Check if CloudFormation stack exists
stack_exists() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        &>/dev/null
    return $?
}

# Delete CloudFormation stack
delete_stack() {
    if ! stack_exists; then
        log_info "CloudFormation stack '$STACK_NAME' not found (already deleted)"
        return 0
    fi
    
    log_info "Deleting CloudFormation stack: $STACK_NAME"
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    log_info "Waiting for stack deletion to complete..."
    
    if aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION" 2>/dev/null; then
        log_info "CloudFormation stack deleted successfully"
    else
        log_warn "Stack deletion completed (may have already been deleted)"
    fi
}

# Find orphaned Load Balancers created by Kubernetes
find_load_balancers() {
    # Note: Don't output log messages here as this function's output is captured
    
    # Classic Load Balancers
    local clbs=$(aws elb describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancerDescriptions[?contains(LoadBalancerName, 'percona') || contains(LoadBalancerName, '$CLUSTER_NAME')].LoadBalancerName" \
        --output text 2>/dev/null)
    
    # Application/Network Load Balancers
    local albs=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'percona') || contains(LoadBalancerName, '$CLUSTER_NAME')].LoadBalancerArn" \
        --output text 2>/dev/null)
    
    # Also check by tags
    local tagged_albs=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[*].LoadBalancerArn" \
        --output text 2>/dev/null | while read -r arn; do
        if aws elbv2 describe-tags --resource-arns "$arn" --region "$REGION" 2>/dev/null | \
           grep -q "kubernetes.io/cluster/$CLUSTER_NAME"; then
            echo "$arn"
        fi
    done)
    
    {
        echo "$clbs"
        echo "$albs"
        echo "$tagged_albs"
    } | grep -v '^$' | sort -u
}

# Delete orphaned Load Balancers
delete_load_balancers() {
    log_info "Searching for orphaned Load Balancers..."
    
    local lbs=$(find_load_balancers)
    
    if [ -z "$lbs" ]; then
        log_info "No orphaned Load Balancers found"
        return 0
    fi
    
    local lb_count=$(echo "$lbs" | wc -l)
    log_warn "Found $lb_count orphaned Load Balancer(s):"
    echo ""
    
    # Display each load balancer with details
    echo "$lbs" | while read -r lb; do
        if [[ $lb == arn:* ]]; then
            # ALB/NLB - extract name from ARN
            local lb_name=$(echo "$lb" | awk -F'/' '{print $2}')
            local lb_type=$(echo "$lb" | grep -o 'loadbalancer/[^/]*' | cut -d'/' -f2)
            echo "  - Type: ALB/NLB"
            echo "    Name: $lb_name"
            echo "    ARN: $lb"
        else
            # Classic LB
            echo "  - Type: Classic Load Balancer"
            echo "    Name: $lb"
        fi
        echo ""
    done
    
    read -p "Do you want to delete these Load Balancers? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping Load Balancer deletion"
        return 0
    fi
    
    log_info "Deleting Load Balancers..."
    
    echo "$lbs" | while read -r lb; do
        if [[ $lb == arn:* ]]; then
            # ALB/NLB
            local lb_name=$(echo "$lb" | awk -F'/' '{print $2}')
            log_info "Deleting ALB/NLB: $lb_name"
            if aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region "$REGION" 2>/dev/null; then
                log_info "✓ Deleted: $lb_name"
            else
                log_error "✗ Failed to delete: $lb_name"
            fi
        else
            # Classic LB
            log_info "Deleting Classic LB: $lb"
            if aws elb delete-load-balancer --load-balancer-name "$lb" --region "$REGION" 2>/dev/null; then
                log_info "✓ Deleted: $lb"
            else
                log_error "✗ Failed to delete: $lb"
            fi
        fi
    done
    
    log_info "Load Balancer cleanup completed"
}

# Find orphaned Security Groups
find_security_groups() {
    # Note: Don't output log messages here as this function's output is captured
    
    aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
        --query 'SecurityGroups[*].[GroupId,GroupName]' \
        --output text 2>/dev/null
}

# Delete orphaned Security Groups
delete_security_groups() {
    log_info "Searching for orphaned Security Groups..."
    
    local sgs=$(find_security_groups)
    
    if [ -z "$sgs" ]; then
        log_info "No orphaned Security Groups found"
        return 0
    fi
    
    local sg_count=$(echo "$sgs" | wc -l)
    log_warn "Found $sg_count orphaned Security Group(s):"
    echo "$sgs" | while read -r sg_id sg_name; do
        echo "  - $sg_id ($sg_name)"
    done
    echo ""
    
    read -p "Do you want to delete these Security Groups? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping Security Group deletion"
        return 0
    fi
    
    log_info "Deleting Security Groups..."
    log_info "Note: This may take multiple attempts due to dependencies"
    
    # Try multiple times as SGs may have dependencies
    for attempt in {1..3}; do
        echo "$sgs" | while read -r sg_id sg_name; do
            if aws ec2 delete-security-group --group-id "$sg_id" --region "$REGION" 2>/dev/null; then
                log_info "✓ Deleted: $sg_id"
            else
                log_warn "Cannot delete $sg_id yet (may have dependencies, will retry)"
            fi
        done
        
        if [ $attempt -lt 3 ]; then
            sleep 5
        fi
    done
    
    log_info "Security Group cleanup completed"
}

# Find orphaned NAT Gateways
find_nat_gateways() {
    # Note: Don't output log messages here as this function's output is captured
    
    # Find by VPC tag first
    local vpc_id=$(aws ec2 describe-vpcs \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null)
    
    if [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ]; then
        aws ec2 describe-nat-gateways \
            --region "$REGION" \
            --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available" \
            --query 'NatGateways[*].[NatGatewayId,VpcId,State,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null
    fi
    
    # Also search by name pattern
    aws ec2 describe-nat-gateways \
        --region "$REGION" \
        --filter "Name=state,Values=available" \
        --query 'NatGateways[*].[NatGatewayId,VpcId,State,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null | grep -i "percona\|$CLUSTER_NAME" || true
}

# Delete orphaned NAT Gateways
delete_nat_gateways() {
    log_info "Searching for orphaned NAT Gateways..."
    
    local nats=$(find_nat_gateways | sort -u)
    
    if [ -z "$nats" ]; then
        log_info "No orphaned NAT Gateways found"
        return 0
    fi
    
    local nat_count=$(echo "$nats" | wc -l)
    log_warn "Found $nat_count orphaned NAT Gateway(s):"
    log_warn "Cost: ~\$32/month per NAT Gateway = ~\$$(( nat_count * 32 ))/month"
    echo ""
    echo "$nats" | while read -r nat_id vpc_id state name; do
        echo "  - $nat_id (VPC: $vpc_id, ${name:-unnamed})"
    done
    echo ""
    
    read -p "Do you want to delete these NAT Gateways? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping NAT Gateway deletion"
        return 0
    fi
    
    log_info "Deleting NAT Gateways..."
    log_warn "Note: NAT Gateway deletion takes several minutes"
    
    echo "$nats" | while read -r nat_id vpc_id state name; do
        log_info "Deleting NAT Gateway: $nat_id"
        if aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --region "$REGION" 2>/dev/null; then
            log_info "✓ Deletion initiated for: $nat_id (will complete in ~5 minutes)"
        else
            log_error "✗ Failed to delete: $nat_id"
        fi
    done
    
    log_info "NAT Gateway cleanup completed (deletion in progress)"
}

# Find orphaned Elastic IPs
find_elastic_ips() {
    # Note: Don't output log messages here as this function's output is captured
    
    # Find unassociated EIPs that were used by the cluster
    aws ec2 describe-addresses \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
        --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null
}

# Delete orphaned Elastic IPs
delete_elastic_ips() {
    log_info "Searching for orphaned Elastic IPs..."
    
    local eips=$(find_elastic_ips)
    
    if [ -z "$eips" ]; then
        log_info "No orphaned Elastic IPs found"
        return 0
    fi
    
    local eip_count=$(echo "$eips" | wc -l)
    log_warn "Found $eip_count orphaned Elastic IP(s):"
    log_warn "Cost: ~\$3.60/month per unattached EIP = ~\$$(echo "scale=2; $eip_count * 3.60" | bc 2>/dev/null || echo "N/A")/month"
    echo ""
    echo "$eips" | while read -r alloc_id public_ip name; do
        echo "  - $alloc_id ($public_ip) ${name:-unnamed}"
    done
    echo ""
    
    read -p "Do you want to release these Elastic IPs? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping Elastic IP release"
        return 0
    fi
    
    log_info "Releasing Elastic IPs..."
    
    echo "$eips" | while read -r alloc_id public_ip name; do
        log_info "Releasing EIP: $alloc_id ($public_ip)"
        if aws ec2 release-address --allocation-id "$alloc_id" --region "$REGION" 2>/dev/null; then
            log_info "✓ Released: $alloc_id"
        else
            log_error "✗ Failed to release: $alloc_id (may still be attached)"
        fi
    done
    
    log_info "Elastic IP cleanup completed"
}

# Find orphaned Network Interfaces
find_network_interfaces() {
    # Note: Don't output log messages here as this function's output is captured
    
    aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].[NetworkInterfaceId,Description]' \
        --output text 2>/dev/null
}

# Delete orphaned Network Interfaces
delete_network_interfaces() {
    log_info "Searching for orphaned Network Interfaces..."
    
    local enis=$(find_network_interfaces)
    
    if [ -z "$enis" ]; then
        log_info "No orphaned Network Interfaces found"
        return 0
    fi
    
    local eni_count=$(echo "$enis" | wc -l)
    log_warn "Found $eni_count orphaned Network Interface(s):"
    echo "$enis" | while read -r eni_id desc; do
        echo "  - $eni_id ($desc)"
    done
    echo ""
    
    read -p "Do you want to delete these Network Interfaces? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping Network Interface deletion"
        return 0
    fi
    
    log_info "Deleting Network Interfaces..."
    
    echo "$enis" | while read -r eni_id desc; do
        if aws ec2 delete-network-interface --network-interface-id "$eni_id" --region "$REGION" 2>/dev/null; then
            log_info "✓ Deleted: $eni_id"
        else
            log_error "✗ Failed to delete: $eni_id (may be attached)"
        fi
    done
    
    log_info "Network Interface cleanup completed"
}

# Display summary of what will be checked
show_cleanup_plan() {
    echo ""
    log_info "╔════════════════════════════════════════════════════════════╗"
    log_info "║         EKS Cluster Cleanup - Resource Scanner            ║"
    log_info "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "This script will check for and optionally delete:"
    echo "  • CloudFormation stack (if exists)"
    echo "  • Orphaned NAT Gateways (~\$32/month each!)"
    echo "  • Orphaned Elastic IPs (~\$3.60/month each)"
    echo "  • Orphaned EBS volumes"
    echo "  • Orphaned Load Balancers"
    echo "  • Orphaned Network Interfaces"
    echo "  • Orphaned Security Groups"
    echo ""
}

# Main execution
main() {
    # Check AWS credentials first
    check_aws_credentials
    
    show_cleanup_plan
    
    log_warn "This will scan for and potentially delete EKS cluster resources!"
    read -p "Do you want to continue? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    echo ""
    log_info "Starting EKS cluster cleanup scan..."
    echo ""
    
    # Step 1: Delete the CloudFormation stack if it exists
    delete_stack
    
    # Step 2: Wait for resources to fully terminate
    if stack_exists; then
        log_info "Waiting for resources to fully terminate..."
        sleep 10
    fi
    
    echo ""
    log_info "Scanning for orphaned resources..."
    echo ""
    
    # Step 3: Clean up Load Balancers (do this early as they have dependencies)
    delete_load_balancers
    echo ""
    
    # Step 4: Clean up NAT Gateways (expensive! ~$32/month each)
    delete_nat_gateways
    echo ""
    
    # Step 5: Wait for NAT Gateways to start deleting before cleaning up EIPs
    if [ -n "$(find_nat_gateways)" ]; then
        log_info "Waiting 30 seconds for NAT Gateway deletion to begin..."
        sleep 30
    fi
    
    # Step 6: Clean up Elastic IPs (after NAT Gateways)
    delete_elastic_ips
    echo ""
    
    # Step 7: Clean up EBS volumes
    delete_volumes
    echo ""
    
    # Step 8: Clean up Network Interfaces
    delete_network_interfaces
    echo ""
    
    # Step 9: Clean up Security Groups (do this last due to dependencies)
    delete_security_groups
    echo ""
    
    log_info "════════════════════════════════════════════════════════════"
    log_info "  EKS cluster cleanup completed!"
    log_info "════════════════════════════════════════════════════════════"
    echo ""
    log_info "Recommendations:"
    echo "  1. Verify all resources deleted in AWS Console"
    echo "  2. Check for any remaining costs in Cost Explorer"
    echo "  3. Re-run this script to catch any missed resources"
    echo ""
    log_info "AWS Console Links:"
    echo "  • NAT Gateways: https://console.aws.amazon.com/vpc/home?region=$REGION#NatGateways:"
    echo "  • Elastic IPs: https://console.aws.amazon.com/ec2/v2/home?region=$REGION#Addresses:"
    echo "  • EC2 Volumes: https://console.aws.amazon.com/ec2/v2/home?region=$REGION#Volumes:"
    echo "  • Load Balancers: https://console.aws.amazon.com/ec2/v2/home?region=$REGION#LoadBalancers:"
    echo "  • Security Groups: https://console.aws.amazon.com/ec2/v2/home?region=$REGION#SecurityGroups:"
    echo "  • Cost Explorer: https://console.aws.amazon.com/cost-management/home?region=$REGION#/dashboard"
    echo ""
}

# Run main function
main "$@"




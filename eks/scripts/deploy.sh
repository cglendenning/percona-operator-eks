#!/bin/bash

# EKS Cluster Deployment Script
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
TEMPLATE_FILE="eks/cloudformation/eks-cluster.yaml"
REGION="us-east-1"
CLUSTER_NAME="percona-eks"
NODE_INSTANCE_TYPE="m6i.xlarge"  # Balanced for multi-cluster: 4 vCPU, 16GB RAM, $0.192/hr - 15% faster than m5.xlarge
USE_SPOT="false"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Verbosity levels
VERBOSE=${VERBOSE:-1}
DEBUG=${DEBUG:-0}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

log_verbose() {
    if [ "$VERBOSE" -ge 1 ]; then
        echo -e "${CYAN}[VERBOSE]${NC} $1"
    fi
}

log_step() {
    echo -e "${BOLD}${GREEN}[STEP]${NC} $1"
}

log_command() {
    if [ "$VERBOSE" -ge 2 ]; then
        echo -e "${YELLOW}[CMD]${NC} $1"
    fi
}

# Error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Error occurred on line $line_number with exit code $exit_code"
    log_error "Stack trace:"
    local i=1
    while caller $i; do
        ((i++))
    done
    exit $exit_code
}

trap 'handle_error $LINENO' ERR

# Progress indicators
show_progress() {
    local message="$1"
    local duration="$2"
    log_verbose "$message (this may take $duration)"
}

# Monitor CloudFormation stack events in real-time
monitor_stack_events() {
    local last_event_time=""
    local event_count=0
    
    log_verbose "Monitoring CloudFormation stack events..."
    
    while true; do
        # Get all events and sort by timestamp
        local events=$(aws cloudformation describe-stack-events \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
            --output text 2>/dev/null | sort -k1)
        
        if [ -n "$events" ]; then
            local current_count=$(echo "$events" | wc -l)
            
            # Only show new events
            if [ "$current_count" -gt "$event_count" ]; then
                echo "$events" | tail -n +$((event_count + 1)) | while IFS=$'\t' read -r timestamp resource_id status reason; do
                    if [ -n "$timestamp" ] && [ -n "$resource_id" ] && [ -n "$status" ]; then
                        # Format the timestamp for display (handle both GNU and BSD date)
                        local display_time=""
                        if [ "$OS_TYPE" = "macos" ]; then
                            # macOS uses BSD date
                            display_time=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${timestamp:0:19}" "+%H:%M:%S" 2>/dev/null || echo "${timestamp:11:8}")
                        else
                            # Linux/WSL uses GNU date
                            display_time=$(date -d "$timestamp" "+%H:%M:%S" 2>/dev/null || echo "${timestamp:11:8}")
                        fi
                        
                        # Color code the status
                        local status_color=""
                        case "$status" in
                            *CREATE_COMPLETE*|*UPDATE_COMPLETE*)
                                status_color="${GREEN}"
                                ;;
                            *CREATE_IN_PROGRESS*|*UPDATE_IN_PROGRESS*)
                                status_color="${YELLOW}"
                                ;;
                            *CREATE_FAILED*|*UPDATE_FAILED*|*DELETE_FAILED*)
                                status_color="${RED}"
                                ;;
                            *ROLLBACK*)
                                status_color="${RED}"
                                ;;
                            *)
                                status_color="${CYAN}"
                                ;;
                        esac
                        
                        # Display the event
                        echo -e "${BLUE}[${display_time}]${NC} ${status_color}${resource_id}${NC}: ${status_color}${status}${NC}"
                        if [ -n "$reason" ] && [ "$reason" != "None" ] && [ "$reason" != "null" ]; then
                            echo -e "  ${CYAN}Reason:${NC} $reason"
                        fi
                    fi
                done
                event_count=$current_count
            fi
        fi
        
        # Check if stack is in a terminal state
        local stack_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
        case "$stack_status" in
            CREATE_COMPLETE|UPDATE_COMPLETE|CREATE_FAILED|UPDATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_COMPLETE)
                log_verbose "Stack reached terminal state: $stack_status"
                break
                ;;
        esac
        
        # Wait before next check
        sleep 3
    done
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Execute command with verbose output
execute_command() {
    local cmd="$1"
    local description="$2"
    
    log_command "Executing: $cmd"
    log_verbose "$description"
    
    if [ "$VERBOSE" -ge 2 ]; then
        eval "$cmd"
    else
        eval "$cmd" 2>&1 | while IFS= read -r line; do
            log_verbose "$line"
        done
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check AWS CLI
    log_verbose "Checking AWS CLI installation..."
    if ! command_exists aws; then
        log_error "AWS CLI is not installed"
        log_error "Please install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi
    
    local aws_version=$(aws --version 2>&1)
    log_verbose "AWS CLI version: $aws_version"
    
    # Check kubectl
    log_verbose "Checking kubectl installation..."
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        log_error "Please install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        exit 1
    fi
    
    local kubectl_version=$(kubectl version --client --short 2>&1)
    log_verbose "kubectl version: $kubectl_version"
    
    # Check AWS credentials
    log_verbose "Checking AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        log_error "Please configure AWS credentials using:"
        log_error "  aws configure"
        log_error "  or set AWS_PROFILE environment variable"
        exit 1
    fi
    
    local aws_identity=$(aws sts get-caller-identity --output json 2>/dev/null)
    local aws_user=$(echo "$aws_identity" | jq -r '.Arn // "Unknown"')
    local aws_account=$(echo "$aws_identity" | jq -r '.Account // "Unknown"')
    log_verbose "AWS Identity: $aws_user"
    log_verbose "AWS Account: $aws_account"
    
    # Check AWS region
    log_verbose "Checking AWS region..."
    local current_region=$(aws configure get region 2>/dev/null || echo "Not set")
    log_verbose "Current AWS region: $current_region"
    log_verbose "Target region: $REGION"
    
    # Check if template file exists
    log_verbose "Checking CloudFormation template..."
    if [ ! -f "$TEMPLATE_FILE" ]; then
        log_error "CloudFormation template not found: $TEMPLATE_FILE"
        exit 1
    fi
    log_verbose "Template file found: $TEMPLATE_FILE"
    
    # Check template validity
    log_verbose "Validating CloudFormation template..."
    if aws cloudformation validate-template --template-body file://"$TEMPLATE_FILE" --region "$REGION" &>/dev/null; then
        log_verbose "Template validation successful"
    else
        log_warn "Template validation failed, but continuing..."
    fi
    
    log_info "Prerequisites check passed"
}

# Deploy CloudFormation stack
deploy_stack() {
    log_step "Deploying EKS cluster with CloudFormation..."
    
    # Check if stack already exists
    log_verbose "Checking if stack already exists..."
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &>/dev/null; then
        log_verbose "Stack exists, will update it"
        local stack_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text)
        log_verbose "Current stack status: $stack_status"
        
        if [ "$stack_status" = "ROLLBACK_COMPLETE" ] || [ "$stack_status" = "ROLLBACK_FAILED" ] || [ "$stack_status" = "UPDATE_ROLLBACK_COMPLETE" ] || [ "$stack_status" = "UPDATE_ROLLBACK_FAILED" ]; then
            log_warn "Stack is in $stack_status state, deleting it first..."
            aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
            log_verbose "Waiting for stack deletion to complete..."
            aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
            log_verbose "Stack deletion completed"
        fi
    else
        log_verbose "Stack does not exist, will create it"
    fi
    
    # Display deployment parameters
    log_verbose "Deployment parameters:"
    log_verbose "  Stack Name: $STACK_NAME"
    log_verbose "  Template: $TEMPLATE_FILE"
    log_verbose "  Region: $REGION"
    log_verbose "  Cluster Name: $CLUSTER_NAME"
    log_verbose "  Node Instance Type: $NODE_INSTANCE_TYPE"
    log_verbose "  Node Groups: 3 (one per AZ: us-east-1a, us-east-1c, us-east-1d)"
    log_verbose "  Use Spot Instances: $USE_SPOT"
    
    # Deploy the stack
    show_progress "Deploying CloudFormation stack" "15-20 minutes"
    
    local deploy_cmd="aws cloudformation deploy \
        --template-file \"$TEMPLATE_FILE\" \
        --stack-name \"$STACK_NAME\" \
        --parameter-overrides \
            ClusterName=\"$CLUSTER_NAME\" \
            NodeInstanceType=\"$NODE_INSTANCE_TYPE\" \
            UseSpotInstances=\"$USE_SPOT\" \
        --capabilities CAPABILITY_IAM \
        --region \"$REGION\""
    
    log_command "$deploy_cmd"
    
    if [ "$VERBOSE" -ge 2 ]; then
        # For very verbose mode, show real-time CloudFormation events
        log_verbose "Starting CloudFormation deployment with real-time event monitoring..."
        
        # Start the deployment in the background
        eval "$deploy_cmd" &
        local deploy_pid=$!
        
        # Monitor stack events in the background
        monitor_stack_events &
        local monitor_pid=$!
        
        # Wait for deployment to complete
        wait $deploy_pid
        local deploy_result=$?
        
        # Stop monitoring
        kill $monitor_pid 2>/dev/null || true
        
        if [ $deploy_result -ne 0 ]; then
            log_error "CloudFormation deployment failed"
            exit 1
        fi
    elif [ "$VERBOSE" -ge 1 ]; then
        # For normal verbose mode, show basic progress
        log_verbose "Starting CloudFormation deployment..."
        eval "$deploy_cmd" 2>&1 | while IFS= read -r line; do
            log_verbose "$line"
        done
    else
        # For minimal output, just run the command
        eval "$deploy_cmd" >/dev/null 2>&1
    fi
    
    # Check deployment status
    local final_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text)
    log_verbose "Final stack status: $final_status"
    
    if [ "$final_status" = "CREATE_COMPLETE" ] || [ "$final_status" = "UPDATE_COMPLETE" ]; then
        log_info "CloudFormation stack deployed successfully"
    else
        log_error "Stack deployment failed with status: $final_status"
        log_error "Check CloudFormation console for details: https://console.aws.amazon.com/cloudformation/home?region=$REGION#/stacks"
        exit 1
    fi
}

# Wait for cluster to be ready
wait_for_cluster() {
    log_step "Waiting for EKS cluster to be ready..."
    
    show_progress "Waiting for EKS cluster to become active" "5-10 minutes"
    
    # Check initial cluster status
    log_verbose "Checking initial cluster status..."
    local initial_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")
    log_verbose "Initial cluster status: $initial_status"
    
    # Wait for cluster to be active
    log_verbose "Waiting for cluster to become active..."
    aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION"
    
    # Verify cluster is ready
    local final_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status' --output text)
    log_verbose "Final cluster status: $final_status"
    
    if [ "$final_status" = "ACTIVE" ]; then
        log_info "EKS cluster is ready"
        
        # Get cluster details
        local cluster_info=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --output json)
        local cluster_version=$(echo "$cluster_info" | jq -r '.cluster.version // "Unknown"')
        local cluster_endpoint=$(echo "$cluster_info" | jq -r '.cluster.endpoint // "Unknown"')
        local cluster_arn=$(echo "$cluster_info" | jq -r '.cluster.arn // "Unknown"')
        
        log_verbose "Cluster details:"
        log_verbose "  Version: $cluster_version"
        log_verbose "  Endpoint: $cluster_endpoint"
        log_verbose "  ARN: $cluster_arn"
    else
        log_error "Cluster is not in ACTIVE state: $final_status"
        exit 1
    fi
}

# Update kubeconfig
update_kubeconfig() {
    log_step "Updating kubeconfig..."
    
    log_verbose "Updating kubeconfig for cluster: $CLUSTER_NAME"
    log_verbose "Region: $REGION"
    
    local kubeconfig_cmd="aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\""
    log_command "$kubeconfig_cmd"
    
    if eval "$kubeconfig_cmd"; then
        log_info "Kubeconfig updated successfully"
        
        # Verify kubectl can connect to the cluster
        log_verbose "Verifying kubectl connection..."
        if kubectl cluster-info &>/dev/null; then
            log_verbose "kubectl connection verified"
            
            # Get cluster info
            local cluster_info=$(kubectl cluster-info 2>/dev/null)
            log_verbose "Cluster info:"
            echo "$cluster_info" | while IFS= read -r line; do
                log_verbose "  $line"
            done
        else
            log_warn "kubectl connection verification failed"
        fi
    else
        log_error "Failed to update kubeconfig"
        exit 1
    fi
}


# Verify node group distribution across AZs
verify_node_distribution() {
    log_step "Verifying nodes are distributed across all AZs..."
    
    # Get list of all node groups
    local nodegroups=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups' --output json)
    local nodegroup_count=$(echo "$nodegroups" | jq '. | length')
    
    log_verbose "Found $nodegroup_count node group(s)"
    
    if [ "$nodegroup_count" -ne 3 ]; then
        log_warn "Expected 3 node groups (one per AZ), found $nodegroup_count"
    fi
    
    # Check each node group and its AZ
    local node_group_azs=()
    echo "$nodegroups" | jq -r '.[]' | while read -r nodegroup_name; do
        log_verbose "Checking node group: $nodegroup_name"
        
        # Get node group status
        local nodegroup_status=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup_name" --region "$REGION" --query 'nodegroup.status' --output text)
        log_verbose "  Status: $nodegroup_status"
        
        # Get node group subnets (which determine AZs)
        local subnets=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup_name" --region "$REGION" --query 'nodegroup.subnets' --output json)
        log_verbose "  Subnets: $(echo "$subnets" | jq -r '.[]' | tr '\n' ' ')"
    done
    
    # Get current node distribution
    local node_azs=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null | tr ' ' '\n' | sort -u)
    local unique_az_count=$(echo "$node_azs" | wc -l)
    
    log_verbose "Current node distribution:"
    echo "$node_azs" | while read -r az; do
        if [ -n "$az" ]; then
            local count=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null | tr ' ' '\n' | grep -c "^$az$")
            log_verbose "  $az: $count node(s)"
        fi
    done
    
    if [ "$unique_az_count" -ge 3 ]; then
        log_info "Nodes are properly distributed across $unique_az_count AZs: $(echo "$node_azs" | tr '\n' ' ')"
    else
        log_error "Nodes are only in $unique_az_count AZ(s): $(echo "$node_azs" | tr '\n' ' ')"
        log_error "Expected nodes in at least 3 AZs (us-east-1a, us-east-1c, us-east-1d)"
        exit 1
    fi
}

# Upgrade EKS add-ons to latest versions
upgrade_addons() {
    log_step "Upgrading EKS add-ons to latest versions..."
    
    # Expected add-ons that should be present
    local expected_addons=("aws-ebs-csi-driver" "vpc-cni" "coredns" "kube-proxy" "metrics-server")
    
    # Get list of currently installed add-ons
    log_verbose "Checking currently installed add-ons..."
    local installed_addons=$(aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'addons' --output json 2>/dev/null)
    local installed_count=$(echo "$installed_addons" | jq '. | length')
    log_verbose "Found $installed_count installed add-ons"
    
    if [ "$installed_count" -eq 0 ]; then
        log_warn "No add-ons found to upgrade"
        return 0
    fi
    
    # Upgrade each add-on
    local upgraded_count=0
    local already_latest_count=0
    local skipped_count=0
    
    for addon_name in "${expected_addons[@]}"; do
        # Check if addon is installed
        if echo "$installed_addons" | jq -e --arg addon "$addon_name" '.[] | select(. == $addon)' >/dev/null 2>&1; then
            log_verbose "Checking addon: $addon_name"
            
            # Get current addon info
            local current_info=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" --region "$REGION" --output json 2>/dev/null)
            local current_version=$(echo "$current_info" | jq -r '.addon.addonVersion')
            local current_status=$(echo "$current_info" | jq -r '.addon.status')
            
            # Skip if addon is currently updating
            if [ "$current_status" = "UPDATING" ] || [ "$current_status" = "CREATING" ]; then
                log_verbose "$addon_name is currently $current_status, skipping upgrade"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            
            # Get available versions
            local versions_info=$(aws eks describe-addon-versions --addon-name "$addon_name" --kubernetes-version "1.34" --region "$REGION" --output json 2>/dev/null)
            local latest_version=$(echo "$versions_info" | jq -r '.addons[0].addonVersions | sort_by(.addonVersion) | reverse | .[0].addonVersion')
            
            if [ "$latest_version" = "null" ] || [ -z "$latest_version" ]; then
                log_warn "Could not determine latest version for $addon_name, skipping"
                continue
            fi
            
            if [ "$current_version" = "$latest_version" ]; then
                log_verbose "$addon_name is already at latest version $latest_version"
                already_latest_count=$((already_latest_count + 1))
                continue
            fi
            
            log_verbose "Upgrading $addon_name from $current_version to $latest_version..."
            local upgrade_cmd="aws eks update-addon --cluster-name \"$CLUSTER_NAME\" --addon-name \"$addon_name\" --addon-version \"$latest_version\" --region \"$REGION\" --resolve-conflicts OVERWRITE"
            log_command "$upgrade_cmd"
            
            if eval "$upgrade_cmd" >/dev/null 2>&1; then
                log_verbose "$addon_name upgrade initiated"
                upgraded_count=$((upgraded_count + 1))
            else
                log_warn "Failed to upgrade $addon_name"
            fi
        else
            log_verbose "$addon_name is not installed, skipping"
        fi
    done
    
    # Wait for upgrades to complete if any were initiated
    if [ "$upgraded_count" -gt 0 ]; then
        log_verbose "Waiting for add-on upgrades to complete (this may take several minutes)..."
        show_progress "Waiting for add-on upgrades" "5-10 minutes"
        
        # Wait for all add-ons to be ACTIVE
        local max_wait=600  # 10 minutes
        local wait_time=0
        local check_interval=30
        
        while [ $wait_time -lt $max_wait ]; do
            local all_active=true
            for addon_name in "${expected_addons[@]}"; do
                if echo "$installed_addons" | jq -e --arg addon "$addon_name" '.[] | select(. == $addon)' >/dev/null 2>&1; then
                    local status=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" --region "$REGION" --query 'addon.status' --output text 2>/dev/null)
                    if [ "$status" != "ACTIVE" ]; then
                        all_active=false
                        break
                    fi
                fi
            done
            
            if [ "$all_active" = true ]; then
                log_verbose "All add-ons are now ACTIVE"
                break
            fi
            
            sleep $check_interval
            wait_time=$((wait_time + check_interval))
        done
    fi
    
    # Provide summary
    if [ "$upgraded_count" -gt 0 ]; then
        log_info "Upgraded $upgraded_count add-on(s) to latest versions"
    fi
    if [ "$already_latest_count" -gt 0 ]; then
        log_verbose "$already_latest_count add-on(s) were already at latest versions"
    fi
    if [ "$skipped_count" -gt 0 ]; then
        log_verbose "$skipped_count add-on(s) were skipped (currently updating/creating)"
    fi
}

# Verify deployment
verify_deployment() {
    log_step "Verifying EKS cluster state..."
    
    # Check cluster status
    local cluster_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status' --output text)
    if [ "$cluster_status" != "ACTIVE" ]; then
        log_error "Cluster is not in ACTIVE state: $cluster_status"
        exit 1
    fi
    
    # Check node groups
    local nodegroups=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups' --output json)
    local nodegroup_count=$(echo "$nodegroups" | jq '. | length')
    if [ "$nodegroup_count" -eq 0 ]; then
        log_error "No node groups found in cluster"
        exit 1
    fi
    
    # Check each node group status
    echo "$nodegroups" | jq -r '.[]' | while read -r nodegroup_name; do
        local nodegroup_status=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup_name" --region "$REGION" --query 'nodegroup.status' --output text)
        if [ "$nodegroup_status" != "ACTIVE" ]; then
            log_error "Node group $nodegroup_name is not in ACTIVE state: $nodegroup_status"
            exit 1
        fi
    done
    
    # Check Kubernetes nodes and verify they're in different AZs
    local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [ "$node_count" -eq 0 ]; then
        log_error "No nodes found in cluster"
        exit 1
    fi
    
    # Get node AZs
    local node_azs=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null | tr ' ' '\n' | sort -u)
    local unique_az_count=$(echo "$node_azs" | wc -l)
    
    # Expected AZs: us-east-1a, us-east-1c, us-east-1d
    local expected_azs=("us-east-1a" "us-east-1c" "us-east-1d")
    local expected_az_count=3
    
    if [ "$unique_az_count" -lt "$expected_az_count" ]; then
        log_error "Nodes are not distributed across $expected_az_count AZs. Found $unique_az_count AZs: $(echo "$node_azs" | tr '\n' ' ')"
        log_error "Expected AZs: ${expected_azs[*]}"
        exit 1
    fi
    
    # Check EKS add-ons
    local addons=$(aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'addons' --output json 2>/dev/null)
    local addon_count=$(echo "$addons" | jq '. | length')
    
    if [ "$addon_count" -lt 5 ]; then
        log_warn "Expected 5 EKS add-ons, found $addon_count"
    fi
    
    log_info "EKS cluster is in desired state:"
    log_info "  ✓ Cluster: ACTIVE"
    log_info "  ✓ Node groups: ACTIVE"
    log_info "  ✓ Nodes: $node_count across $unique_az_count AZs"
    log_info "  ✓ Add-ons: $addon_count installed"
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy an EKS cluster for Percona XtraDB Cluster"
    echo ""
    echo "Options:"
    echo "  -v, --verbose     Increase verbosity (can be used multiple times)"
    echo "  -d, --debug       Enable debug output"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Verbosity Levels:"
    echo "  0 (default)       Minimal output - only errors and final status"
    echo "  1 (-v)            Normal verbosity - shows progress and basic info"
    echo "  2 (-vv)           Very verbose - shows real-time CloudFormation events"
    echo ""
    echo "Environment Variables:"
    echo "  VERBOSE           Set verbosity level (0-2, default: 1)"
    echo "  DEBUG             Enable debug output (0-1, default: 0)"
    echo "  AWS_PROFILE       AWS profile to use"
    echo ""
    echo "Examples:"
    echo "  $0                           # Deploy with normal verbosity"
    echo "  $0 -v                        # Deploy with verbose output"
    echo "  $0 -vv                       # Deploy with very verbose output (real-time events)"
    echo "  $0 -d                        # Deploy with debug output"
    echo "  VERBOSE=2 DEBUG=1 $0         # Deploy with maximum verbosity"
    echo ""
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                ((VERBOSE++))
                shift
                ;;
            -vv)
                # Handle -vv as two verbose flags
                ((VERBOSE++))
                ((VERBOSE++))
                shift
                ;;
            -d|--debug)
                DEBUG=1
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    # Parse command line arguments
    parse_args "$@"
    
    # Display configuration
    log_info "Starting EKS cluster deployment..."
    log_verbose "Configuration:"
    log_verbose "  Verbosity level: $VERBOSE"
    log_verbose "  Debug mode: $DEBUG"
    log_verbose "  AWS Profile: ${AWS_PROFILE:-default}"
    log_verbose "  Stack Name: $STACK_NAME"
    log_verbose "  Cluster Name: $CLUSTER_NAME"
    log_verbose "  Region: $REGION"
    log_verbose "  Node Instance Type: $NODE_INSTANCE_TYPE"
    log_verbose "  Node Groups: 3 (one per AZ)"
    log_verbose "  Use Spot Instances: $USE_SPOT"
    
    # Record start time
    local start_time=$(date +%s)
    
    # Execute deployment steps
    check_prerequisites
    deploy_stack
    wait_for_cluster
    update_kubeconfig
    verify_node_distribution
    upgrade_addons
    verify_deployment
    
    # Calculate deployment time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    # Success message
    log_info "EKS cluster deployment completed successfully!"
    log_info "Cluster name: $CLUSTER_NAME"
    log_info "Region: $REGION"
    log_info "Deployment time: ${minutes}m ${seconds}s"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Install Percona XtraDB Cluster:"
    log_info "     ./percona/eks/install.sh"
    log_info ""
    log_info "  2. Or set environment variables and install non-interactively:"
    log_info "     NAMESPACE=percona CLUSTER_NAME=pxc-cluster PXC_NODES=3 ./percona/eks/install.sh"
}

# Run main function
main "$@"

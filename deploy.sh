#!/bin/bash

# EKS Cluster Deployment Script
set -e

# Configuration
STACK_NAME="percona-eks-cluster"
TEMPLATE_FILE="cloudformation/eks-cluster.yaml"
REGION="us-east-1"
CLUSTER_NAME="percona-eks"
NODE_INSTANCE_TYPE="m6i.large"
NODE_DESIRED_SIZE="3"
NODE_MIN_SIZE="3"
NODE_MAX_SIZE="6"
USE_SPOT="true"

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
                        if command -v gdate >/dev/null 2>&1; then
                            display_time=$(gdate -d "$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
                        else
                            display_time=$(date -j -f "%Y-%m-%dT%H:%M:%S.%3NZ" "$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
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
        
        if [ "$stack_status" = "ROLLBACK_COMPLETE" ] || [ "$stack_status" = "ROLLBACK_FAILED" ]; then
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
    log_verbose "  Node Desired Size: $NODE_DESIRED_SIZE"
    log_verbose "  Node Min Size: $NODE_MIN_SIZE"
    log_verbose "  Node Max Size: $NODE_MAX_SIZE"
    log_verbose "  Use Spot Instances: $USE_SPOT"
    
    # Deploy the stack
    show_progress "Deploying CloudFormation stack" "10-15 minutes"
    
    local deploy_cmd="aws cloudformation deploy \
        --template-file \"$TEMPLATE_FILE\" \
        --stack-name \"$STACK_NAME\" \
        --parameter-overrides \
            ClusterName=\"$CLUSTER_NAME\" \
            NodeInstanceType=\"$NODE_INSTANCE_TYPE\" \
            NodeGroupDesiredSize=\"$NODE_DESIRED_SIZE\" \
            NodeGroupMinSize=\"$NODE_MIN_SIZE\" \
            NodeGroupMaxSize=\"$NODE_MAX_SIZE\" \
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

# Install EBS CSI driver
install_ebs_csi() {
    log_step "Installing EBS CSI driver..."
    
    # Get the EBS CSI driver role ARN from CloudFormation outputs
    log_verbose "Retrieving EBS CSI driver role ARN from CloudFormation outputs..."
    local ebs_csi_role_arn=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`EBSCSIDriverRoleArn`].OutputValue' \
        --output text)
    
    if [ -z "$ebs_csi_role_arn" ]; then
        log_error "Could not get EBS CSI driver role ARN from CloudFormation outputs"
        log_error "Make sure the CloudFormation stack was deployed successfully"
        exit 1
    fi
    
    log_verbose "EBS CSI driver role ARN: $ebs_csi_role_arn"
    
    # Install EBS CSI driver
    log_verbose "Installing EBS CSI driver from Kubernetes manifests..."
    local ebs_install_url="https://github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.28"
    log_verbose "Install URL: $ebs_install_url"
    
    local install_cmd="kubectl apply -k \"$ebs_install_url\""
    log_command "$install_cmd"
    
    if eval "$install_cmd"; then
        log_verbose "EBS CSI driver manifests applied successfully"
    else
        log_error "Failed to apply EBS CSI driver manifests"
        exit 1
    fi
    
    # Wait for pods to be created
    log_verbose "Waiting for EBS CSI driver pods to be created..."
    sleep 10
    
    # Annotate the service account
    log_verbose "Annotating EBS CSI controller service account with IAM role..."
    local annotate_cmd="kubectl annotate serviceaccount ebs-csi-controller-sa \
        -n kube-system \
        \"eks.amazonaws.com/role-arn=$ebs_csi_role_arn\" \
        --overwrite"
    log_command "$annotate_cmd"
    
    if eval "$annotate_cmd"; then
        log_verbose "Service account annotated successfully"
    else
        log_warn "Failed to annotate service account, but continuing..."
    fi
    
    # Restart the EBS CSI driver pods
    log_verbose "Restarting EBS CSI controller deployment..."
    local restart_cmd="kubectl rollout restart deployment ebs-csi-controller -n kube-system"
    log_command "$restart_cmd"
    
    if eval "$restart_cmd"; then
        log_verbose "EBS CSI controller deployment restart initiated"
    else
        log_warn "Failed to restart EBS CSI controller deployment"
    fi
    
    # Wait for pods to be ready
    log_verbose "Waiting for EBS CSI driver pods to be ready..."
    show_progress "Waiting for EBS CSI driver pods to be ready" "2-3 minutes"
    
    if kubectl wait --for=condition=ready pod -l app=ebs-csi-controller -n kube-system --timeout=300s; then
        log_verbose "EBS CSI driver pods are ready"
    else
        log_warn "EBS CSI driver pods may not be ready yet"
    fi
    
    # Verify installation
    log_verbose "Verifying EBS CSI driver installation..."
    local pod_status=$(kubectl get pods -l app=ebs-csi-controller -n kube-system --no-headers 2>/dev/null | wc -l)
    log_verbose "Number of EBS CSI controller pods: $pod_status"
    
    log_info "EBS CSI driver installed and configured"
}

# Verify deployment
verify_deployment() {
    log_step "Verifying deployment..."
    
    # Check cluster status
    log_verbose "Checking EKS cluster status..."
    local cluster_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.status' --output text)
    log_verbose "Cluster status: $cluster_status"
    
    if [ "$cluster_status" != "ACTIVE" ]; then
        log_error "Cluster is not in ACTIVE state: $cluster_status"
        exit 1
    fi
    
    # Check node groups
    log_verbose "Checking node groups..."
    local nodegroups=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups' --output json)
    local nodegroup_count=$(echo "$nodegroups" | jq '. | length')
    log_verbose "Number of node groups: $nodegroup_count"
    
    if [ "$nodegroup_count" -eq 0 ]; then
        log_error "No node groups found in cluster"
        exit 1
    fi
    
    # Check each node group
    echo "$nodegroups" | jq -r '.[]' | while read -r nodegroup_name; do
        log_verbose "Checking node group: $nodegroup_name"
        local nodegroup_status=$(aws eks describe-nodegroup \
            --cluster-name "$CLUSTER_NAME" \
            --nodegroup-name "$nodegroup_name" \
            --region "$REGION" \
            --query 'nodegroup.status' \
            --output text)
        log_verbose "Node group $nodegroup_name status: $nodegroup_status"
        
        if [ "$nodegroup_status" != "ACTIVE" ]; then
            log_warn "Node group $nodegroup_name is not in ACTIVE state: $nodegroup_status"
        fi
    done
    
    # Check nodes
    log_verbose "Checking Kubernetes nodes..."
    local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_verbose "Number of nodes: $node_count"
    
    if [ "$node_count" -eq 0 ]; then
        log_error "No nodes found in cluster"
        exit 1
    fi
    
    # Display node information
    log_verbose "Node details:"
    kubectl get nodes -o wide | while IFS= read -r line; do
        log_verbose "  $line"
    done
    
    # Check EBS CSI driver
    log_verbose "Checking EBS CSI driver status..."
    local ebs_pods=$(kubectl get pods -l app=ebs-csi-controller -n kube-system --no-headers 2>/dev/null | wc -l)
    log_verbose "EBS CSI controller pods: $ebs_pods"
    
    if [ "$ebs_pods" -gt 0 ]; then
        local ebs_ready=$(kubectl get pods -l app=ebs-csi-controller -n kube-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        log_verbose "EBS CSI controller ready pods: $ebs_ready"
    fi
    
    # Check system pods
    log_verbose "Checking system pods..."
    local system_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)
    log_verbose "System pods: $system_pods"
    
    log_info "Deployment verification completed successfully"
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
    log_verbose "  Node Count: $NODE_DESIRED_SIZE"
    log_verbose "  Use Spot Instances: $USE_SPOT"
    
    # Record start time
    local start_time=$(date +%s)
    
    # Execute deployment steps
    check_prerequisites
    deploy_stack
    wait_for_cluster
    update_kubeconfig
    install_ebs_csi
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
    log_info "  1. Verify cluster access: kubectl get nodes"
    log_info "  2. Deploy Percona XtraDB Cluster"
    log_info "  3. Check EBS CSI driver: kubectl get pods -n kube-system -l app=ebs-csi-controller"
    log_info ""
    log_info "Useful commands:"
    log_info "  kubectl get nodes                    # List cluster nodes"
    log_info "  kubectl get pods -A                  # List all pods"
    log_info "  aws eks describe-cluster --name $CLUSTER_NAME --region $REGION  # Cluster details"
}

# Run main function
main "$@"

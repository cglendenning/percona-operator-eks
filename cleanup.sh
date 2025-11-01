#!/bin/bash

# EKS Cluster Cleanup Script
set -e

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

# Delete CloudFormation stack
delete_stack() {
    log_info "Deleting CloudFormation stack: $STACK_NAME"
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    log_info "Waiting for stack deletion to complete..."
    
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    log_info "CloudFormation stack deleted successfully"
}

# Main execution
main() {
    log_warn "This will delete the entire EKS cluster and all associated resources!"
    read -p "Are you sure you want to continue? (yes/no): " -r
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    log_info "Starting EKS cluster cleanup..."
    
    delete_stack
    
    log_info "EKS cluster cleanup completed successfully!"
}

# Run main function
main "$@"




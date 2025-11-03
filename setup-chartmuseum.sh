#!/bin/bash

# ChartMuseum Setup Script for EKS
# This script sets up ChartMuseum with S3 backend on your EKS cluster

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

log_step() {
    echo -e "${BOLD}${GREEN}[STEP]${NC} $1"
}

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-percona-eks}"
NAMESPACE="${NAMESPACE:-chartmuseum}"
CHART_BUCKET_NAME="${CHART_BUCKET_NAME:-}"
SERVICE_TYPE="${SERVICE_TYPE:-LoadBalancer}"  # LoadBalancer, ClusterIP, or NodePort

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    command -v aws >/dev/null 2>&1 || { log_error "aws CLI is required but not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed. Aborting."; exit 1; }
    command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed. Aborting."; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed. Aborting."; exit 1; }
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS credentials not configured"
        exit 1
    fi
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

# Create S3 bucket
create_s3_bucket() {
    log_step "Creating S3 bucket for chart storage..."
    
    if [ -z "$CHART_BUCKET_NAME" ]; then
        CHART_BUCKET_NAME="percona-helm-charts-$(date +%s)"
        log_info "Generated bucket name: ${CHART_BUCKET_NAME}"
    fi
    
    # Check if bucket already exists
    if aws s3 ls "s3://${CHART_BUCKET_NAME}" 2>/dev/null; then
        log_warn "Bucket ${CHART_BUCKET_NAME} already exists"
    else
        log_info "Creating bucket: ${CHART_BUCKET_NAME}"
        aws s3 mb "s3://${CHART_BUCKET_NAME}" --region "${AWS_REGION}"
        
        # Enable versioning
        log_info "Enabling versioning on bucket..."
        aws s3api put-bucket-versioning \
            --bucket "${CHART_BUCKET_NAME}" \
            --versioning-configuration Status=Enabled
        
        # Block public access
        log_info "Blocking public access..."
        aws s3api put-public-access-block \
            --bucket "${CHART_BUCKET_NAME}" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        
        log_info "S3 bucket created successfully"
    fi
    
    echo "${CHART_BUCKET_NAME}" > /tmp/chartmuseum-bucket-name.txt
}

# Setup IAM role for service account (IRSA)
setup_iam_role() {
    log_step "Setting up IAM role for service account..."
    
    # Get cluster OIDC provider
    log_info "Getting cluster OIDC provider..."
    OIDC_PROVIDER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
        --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
    
    if [ -z "$OIDC_PROVIDER" ]; then
        log_error "Could not get OIDC provider. Make sure your cluster has an OIDC provider."
        exit 1
    fi
    
    log_info "OIDC Provider: ${OIDC_PROVIDER}"
    
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    # Create IAM policy
    POLICY_NAME="ChartMuseumS3Policy-${CHART_BUCKET_NAME}"
    log_info "Creating IAM policy: ${POLICY_NAME}"
    
    cat > /tmp/chartmuseum-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${CHART_BUCKET_NAME}",
        "arn:aws:s3:::${CHART_BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF
    
    # Check if policy already exists
    POLICY_ARN=$(aws iam list-policies --scope Local \
        --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text 2>/dev/null || echo "")
    
    if [ -z "$POLICY_ARN" ]; then
        POLICY_ARN=$(aws iam create-policy \
            --policy-name "${POLICY_NAME}" \
            --policy-document file:///tmp/chartmuseum-s3-policy.json \
            --query 'Policy.Arn' --output text)
        log_info "Created IAM policy: ${POLICY_ARN}"
    else
        log_info "IAM policy already exists: ${POLICY_ARN}"
        # Update policy in case bucket changed
        aws iam create-policy-version \
            --policy-arn "${POLICY_ARN}" \
            --policy-document file:///tmp/chartmuseum-s3-policy.json \
            --set-as-default 2>/dev/null || true
    fi
    
    # Create trust policy for service account
    ROLE_NAME="ChartMuseumRole-${CLUSTER_NAME}"
    log_info "Creating IAM role: ${ROLE_NAME}"
    
    cat > /tmp/chartmuseum-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:chartmuseum",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
    
    # Check if role already exists
    ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" \
        --query 'Role.Arn' --output text 2>/dev/null || echo "")
    
    if [ -z "$ROLE_ARN" ]; then
        ROLE_ARN=$(aws iam create-role \
            --role-name "${ROLE_NAME}" \
            --assume-role-policy-document file:///tmp/chartmuseum-trust-policy.json \
            --query 'Role.Arn' --output text)
        log_info "Created IAM role: ${ROLE_ARN}"
    else
        log_info "IAM role already exists: ${ROLE_ARN}"
        # Update trust policy
        aws iam update-assume-role-policy \
            --role-name "${ROLE_NAME}" \
            --policy-document file:///tmp/chartmuseum-trust-policy.json
    fi
    
    # Attach policy to role
    log_info "Attaching policy to role..."
    aws iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "${POLICY_ARN}" 2>/dev/null || log_info "Policy already attached"
    
    echo "${ROLE_ARN}" > /tmp/chartmuseum-role-arn.txt
    log_info "IAM setup complete. Role ARN: ${ROLE_ARN}"
}

# Install ChartMuseum
install_chartmuseum() {
    log_step "Installing ChartMuseum..."
    
    # Read values from previous steps
    CHART_BUCKET_NAME=$(cat /tmp/chartmuseum-bucket-name.txt)
    ROLE_ARN=$(cat /tmp/chartmuseum-role-arn.txt)
    
    # Create namespace
    log_info "Creating namespace: ${NAMESPACE}"
    kubectl create namespace "${NAMESPACE}" 2>/dev/null || log_info "Namespace already exists"
    
    # Create service account with IRSA annotation
    log_info "Creating service account..."
    kubectl create serviceaccount chartmuseum -n "${NAMESPACE}" 2>/dev/null || true
    kubectl annotate serviceaccount chartmuseum \
        -n "${NAMESPACE}" \
        eks.amazonaws.com/role-arn="${ROLE_ARN}" \
        --overwrite
    
    # Add ChartMuseum Helm repo
    log_info "Adding ChartMuseum Helm repository..."
    helm repo add chartmuseum https://chartmuseum.github.io/charts 2>/dev/null || true
    helm repo update
    
    # Check if ChartMuseum is already installed
    if helm list -n "${NAMESPACE}" | grep -q chartmuseum; then
        log_warn "ChartMuseum is already installed. Upgrading..."
        UPGRADE=true
    else
        UPGRADE=false
    fi
    
    # Install/upgrade ChartMuseum
    log_info "Installing ChartMuseum with S3 backend..."
    if [ "$UPGRADE" = true ]; then
        helm upgrade chartmuseum chartmuseum/chartmuseum \
            --namespace "${NAMESPACE}" \
            --set env.open.DISABLE_API=false \
            --set env.open.STORAGE=amazon \
            --set env.open.STORAGE_AMAZON_BUCKET="${CHART_BUCKET_NAME}" \
            --set env.open.STORAGE_AMAZON_REGION="${AWS_REGION}" \
            --set serviceAccount.name=chartmuseum \
            --set service.type="${SERVICE_TYPE}" \
            --wait
    else
        helm install chartmuseum chartmuseum/chartmuseum \
            --namespace "${NAMESPACE}" \
            --set env.open.DISABLE_API=false \
            --set env.open.STORAGE=amazon \
            --set env.open.STORAGE_AMAZON_BUCKET="${CHART_BUCKET_NAME}" \
            --set env.open.STORAGE_AMAZON_REGION="${AWS_REGION}" \
            --set serviceAccount.name=chartmuseum \
            --set service.type="${SERVICE_TYPE}" \
            --wait
    fi
    
    log_info "ChartMuseum installed successfully"
    
    # Wait for service to be ready
    log_info "Waiting for ChartMuseum service to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=chartmuseum \
        -n "${NAMESPACE}" \
        --timeout=300s
    
    # Get service URL
    if [ "$SERVICE_TYPE" = "LoadBalancer" ]; then
        log_info "Waiting for LoadBalancer to be provisioned..."
        sleep 10
        CHARTMUSEUM_URL=""
        MAX_ATTEMPTS=30
        ATTEMPT=0
        while [ -z "$CHARTMUSEUM_URL" ] && [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
            CHARTMUSEUM_URL=$(kubectl get svc chartmuseum -n "${NAMESPACE}" \
                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            if [ -z "$CHARTMUSEUM_URL" ]; then
                CHARTMUSEUM_URL=$(kubectl get svc chartmuseum -n "${NAMESPACE}" \
                    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            fi
            if [ -z "$CHARTMUSEUM_URL" ]; then
                ATTEMPT=$((ATTEMPT + 1))
                sleep 5
            fi
        done
        
        if [ -n "$CHARTMUSEUM_URL" ]; then
            CHARTMUSEUM_URL="http://${CHARTMUSEUM_URL}"
        else
            log_warn "LoadBalancer not ready yet. Using ClusterIP for now."
            CHARTMUSEUM_URL="http://chartmuseum.${NAMESPACE}.svc.cluster.local"
        fi
    else
        CHARTMUSEUM_URL="http://chartmuseum.${NAMESPACE}.svc.cluster.local"
    fi
    
    echo "${CHARTMUSEUM_URL}" > /tmp/chartmuseum-url.txt
    log_info "ChartMuseum URL: ${CHARTMUSEUM_URL}"
}

# Verify installation
verify_installation() {
    log_step "Verifying ChartMuseum installation..."
    
    CHARTMUSEUM_URL=$(cat /tmp/chartmuseum-url.txt)
    
    # Check if ChartMuseum is responding
    log_info "Testing ChartMuseum API..."
    if curl -s "${CHARTMUSEUM_URL}/health" > /dev/null; then
        log_info "✓ ChartMuseum is healthy"
    else
        log_warn "ChartMuseum health check failed (may need more time to start)"
    fi
    
    # Test adding repo
    log_info "Testing Helm repo addition..."
    helm repo add chartmuseum-internal "${CHARTMUSEUM_URL}" 2>/dev/null || true
    helm repo update
    
    # List charts (should be empty initially)
    log_info "Current charts in repository:"
    helm search repo chartmuseum-internal || log_info "No charts yet (expected)"
    
    log_info "ChartMuseum is ready to use!"
}

# Print summary
print_summary() {
    log_step "Installation Summary"
    
    CHART_BUCKET_NAME=$(cat /tmp/chartmuseum-bucket-name.txt)
    ROLE_ARN=$(cat /tmp/chartmuseum-role-arn.txt)
    CHARTMUSEUM_URL=$(cat /tmp/chartmuseum-url.txt)
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ChartMuseum Installation Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  S3 Bucket:     ${CHART_BUCKET_NAME}"
    echo "  IAM Role:      ${ROLE_ARN}"
    echo "  Namespace:     ${NAMESPACE}"
    echo "  ChartMuseum URL: ${CHARTMUSEUM_URL}"
    echo ""
    echo "  To add this repo to Helm:"
    echo "    helm repo add internal ${CHARTMUSEUM_URL}"
    echo "    helm repo update"
    echo ""
    echo "  To mirror external charts, run:"
    echo "    ./mirror-charts.sh"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main execution
main() {
    log_info "Starting ChartMuseum setup for EKS cluster: ${CLUSTER_NAME}"
    log_info "Region: ${AWS_REGION}"
    log_info "Namespace: ${NAMESPACE}"
    log_info "Service Type: ${SERVICE_TYPE}"
    echo ""
    
    check_prerequisites
    create_s3_bucket
    setup_iam_role
    install_chartmuseum
    verify_installation
    print_summary
}

# Run main function
main "$@"


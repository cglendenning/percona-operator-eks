#!/bin/bash
# Percona XtraDB Cluster Installation Script for EKS
# Works on both WSL and macOS

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

# Default configuration
NAMESPACE="${NAMESPACE:-percona}"
CLUSTER_NAME="${CLUSTER_NAME:-pxc-cluster}"
PXC_NODES="${PXC_NODES:-3}"
OPERATOR_VERSION="${OPERATOR_VERSION:-1.15.0}"
PXC_VERSION="${PXC_VERSION:-8.4.6-2}"  # XtraDB 8.4.6
HAPROXY_VERSION="${HAPROXY_VERSION:-2.8.15}"  # HAProxy 2.8.15
STORAGE_CLASS="gp3"  # EKS uses gp3 volumes

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Check prerequisites
check_prerequisites() {
    log_header "Checking Prerequisites"
    
    local missing=()
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    else
        log_success "kubectl found: $(kubectl version --client --short 2>/dev/null | head -n1 || echo 'installed')"
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        missing+=("helm")
    else
        log_success "helm found: $(helm version --short 2>/dev/null || echo 'installed')"
    fi
    
    # Check bc for calculations
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    else
        log_success "bc found (for calculations)"
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them and try again"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please configure kubectl and try again"
        exit 1
    fi
    
    log_success "Connected to Kubernetes cluster"
    
    # Display cluster info
    local cluster_version=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' || echo "unknown")
    log_info "Cluster version: $cluster_version"
}

# Prompt for configuration
prompt_configuration() {
    log_header "Percona XtraDB Cluster Configuration"
    
    echo -e "${CYAN}This script will install:${NC}"
    echo "  - Percona XtraDB Cluster ${PXC_VERSION}"
    echo "  - HAProxy ${HAPROXY_VERSION}"
    echo "  - Percona Operator ${OPERATOR_VERSION}"
    echo "  - All components in namespace: ${NAMESPACE}"
    echo ""
    
    # Prompt for data directory size
    read -p "Enter data directory size per node (e.g., 50Gi, 100Gi) [default: 50Gi]: " data_size
    DATA_DIR_SIZE="${data_size:-50Gi}"
    
    # Validate size format
    if ! [[ "$DATA_DIR_SIZE" =~ ^[0-9]+[GM]i$ ]]; then
        log_error "Invalid size format. Use format like: 50Gi or 100Gi"
        exit 1
    fi
    
    # Prompt for max memory per node
    read -p "Enter max memory per node (e.g., 4Gi, 8Gi, 16Gi) [default: 8Gi]: " max_memory
    MAX_MEMORY="${max_memory:-8Gi}"
    
    # Validate memory format
    if ! [[ "$MAX_MEMORY" =~ ^[0-9]+[GM]i$ ]]; then
        log_error "Invalid memory format. Use format like: 4Gi or 8Gi"
        exit 1
    fi
    
    # Calculate innodb_buffer_pool_size (70% of max memory)
    local memory_value=$(echo "$MAX_MEMORY" | sed 's/[GM]i//')
    local memory_unit=$(echo "$MAX_MEMORY" | sed 's/[0-9]*//')
    
    # Convert to MB for calculation
    local memory_mb
    if [[ "$memory_unit" == "Gi" ]]; then
        memory_mb=$((memory_value * 1024))
    else
        memory_mb=$memory_value
    fi
    
    # Calculate 70%
    local buffer_pool_mb=$(echo "$memory_mb * 0.7 / 1" | bc)
    BUFFER_POOL_SIZE="${buffer_pool_mb%.*}M"
    
    echo ""
    log_info "Configuration Summary:"
    echo "  - Namespace: ${NAMESPACE}"
    echo "  - Cluster Name: ${CLUSTER_NAME}"
    echo "  - Nodes: ${PXC_NODES}"
    echo "  - Data Directory Size: ${DATA_DIR_SIZE}"
    echo "  - Max Memory per Node: ${MAX_MEMORY}"
    echo "  - InnoDB Buffer Pool Size (70%): ${BUFFER_POOL_SIZE}"
    echo "  - Storage Class: ${STORAGE_CLASS}"
    echo "  - PXC Version: ${PXC_VERSION}"
    echo "  - HAProxy Version: ${HAPROXY_VERSION}"
    echo ""
    
    read -p "Proceed with installation? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warn "Installation cancelled by user"
        exit 0
    fi
}

# Create namespace
create_namespace() {
    log_header "Creating Namespace: ${NAMESPACE}"
    
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace ${NAMESPACE} already exists"
    else
        kubectl create namespace "$NAMESPACE"
        log_success "Namespace ${NAMESPACE} created"
    fi
    
    # Label namespace for monitoring
    kubectl label namespace "$NAMESPACE" \
        "app.kubernetes.io/name=percona-xtradb-cluster" \
        "app.kubernetes.io/managed-by=percona-operator" \
        --overwrite
    
    log_success "Namespace labeled"
}

# Install Percona Operator
install_operator() {
    log_header "Installing Percona Operator ${OPERATOR_VERSION}"
    
    # Add Percona Helm repo
    log_info "Adding Percona Helm repository..."
    helm repo add percona https://percona.github.io/percona-helm-charts/ --force-update
    helm repo update
    
    log_success "Helm repository updated"
    
    # Install operator
    log_info "Installing Percona Operator via Helm..."
    helm upgrade --install percona-operator \
        percona/pxc-operator \
        --version "$OPERATOR_VERSION" \
        --namespace "$NAMESPACE" \
        --set watchNamespace="$NAMESPACE" \
        --wait \
        --timeout 5m
    
    log_success "Percona Operator installed"
    
    # Wait for operator to be ready
    log_info "Waiting for operator to be ready..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/percona-xtradb-cluster-operator \
        -n "$NAMESPACE" 2>/dev/null || \
    kubectl wait --for=condition=ready --timeout=300s \
        pod -l app.kubernetes.io/name=percona-xtradb-cluster-operator \
        -n "$NAMESPACE"
    
    log_success "Operator is ready"
}

# Create AWS S3 credentials secret for backups
create_s3_secret() {
    log_header "Creating AWS S3 Credentials Secret"
    
    log_info "Checking for AWS credentials..."
    
    # Try to get AWS credentials from environment or AWS CLI
    local aws_access_key="${AWS_ACCESS_KEY_ID:-}"
    local aws_secret_key="${AWS_SECRET_ACCESS_KEY:-}"
    
    # If not in environment, try AWS CLI config
    if [ -z "$aws_access_key" ] || [ -z "$aws_secret_key" ]; then
        if command -v aws &> /dev/null; then
            log_info "Attempting to read from AWS CLI configuration..."
            aws_access_key=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
            aws_secret_key=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
        fi
    fi
    
    # If still not found, prompt user
    if [ -z "$aws_access_key" ] || [ -z "$aws_secret_key" ]; then
        log_warn "AWS credentials not found in environment or AWS CLI config"
        echo ""
        read -p "Enter AWS Access Key ID: " aws_access_key
        read -s -p "Enter AWS Secret Access Key: " aws_secret_key
        echo ""
    else
        log_success "Found AWS credentials"
    fi
    
    # Check if secret already exists
    if kubectl get secret percona-backup-s3 -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret percona-backup-s3 already exists, skipping creation"
        return
    fi
    
    kubectl create secret generic percona-backup-s3 \
        -n "$NAMESPACE" \
        --from-literal=AWS_ACCESS_KEY_ID="$aws_access_key" \
        --from-literal=AWS_SECRET_ACCESS_KEY="$aws_secret_key"
    
    log_success "AWS S3 credentials secret created"
}

# Generate Helm values
generate_helm_values() {
    log_header "Generating Helm Values"
    
    cat > /tmp/pxc-values.yaml <<EOF
# Percona XtraDB Cluster Configuration for EKS
crVersion: ${PXC_VERSION}

pxc:
  size: ${PXC_NODES}
  image: percona/percona-xtradb-cluster:${PXC_VERSION}
  
  # Configuration for InnoDB
  configuration: |
    [mysqld]
    innodb_buffer_pool_size=${BUFFER_POOL_SIZE}
    innodb_flush_log_at_trx_commit=1
    innodb_flush_method=O_DIRECT
    innodb_log_file_size=512M
    max_connections=500
    
  resources:
    requests:
      memory: $(echo "$MAX_MEMORY" | awk '{printf "%.0fMi", $1 * 0.8}' | sed 's/Gi/*1024/')
      cpu: 1
    limits:
      memory: ${MAX_MEMORY}
      cpu: 2
      
  persistence:
    enabled: true
    size: ${DATA_DIR_SIZE}
    storageClass: ${STORAGE_CLASS}
    
  # EKS Multi-AZ affinity
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - pxc
        topologyKey: topology.kubernetes.io/zone
        
  podDisruptionBudget:
    maxUnavailable: 1

# HAProxy Configuration
haproxy:
  enabled: true
  size: ${PXC_NODES}
  image: percona/percona-xtradb-cluster-haproxy:${HAPROXY_VERSION}
  
  resources:
    requests:
      memory: 256Mi
      cpu: 200m
    limits:
      memory: 512Mi
      cpu: 500m
      
  # EKS Multi-AZ affinity
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - haproxy
        topologyKey: topology.kubernetes.io/zone
        
  podDisruptionBudget:
    maxUnavailable: 1

# ProxySQL disabled (using HAProxy)
proxysql:
  enabled: false

# Backup configuration with AWS S3
backup:
  enabled: true
  image: percona/percona-xtradb-cluster-operator:${OPERATOR_VERSION}-pxc8.0-backup
  
  pitr:
    enabled: true
    storageName: s3
    timeBetweenUploads: 60
    
  storages:
    s3:
      type: s3
      s3:
        bucket: percona-backups-${NAMESPACE}
        region: us-east-1
        credentialsSecret: percona-backup-s3
        
  schedule:
    - name: "daily-full-backup"
      schedule: "0 2 * * *"
      keep: 7
      storageName: s3

# PMM disabled for now (can be enabled later)
pmm:
  enabled: false
EOF
    
    log_success "Helm values generated at /tmp/pxc-values.yaml"
}

# Install PXC Cluster
install_cluster() {
    log_header "Installing Percona XtraDB Cluster: ${CLUSTER_NAME}"
    
    log_info "Installing PXC cluster via Helm..."
    helm upgrade --install "$CLUSTER_NAME" \
        percona/pxc-db \
        --namespace "$NAMESPACE" \
        --values /tmp/pxc-values.yaml \
        --wait \
        --timeout 15m
    
    log_success "PXC cluster Helm chart installed"
    
    # Wait for cluster to be ready
    log_info "Waiting for PXC pods to be ready (this may take several minutes)..."
    
    local timeout=900  # 15 minutes
    local elapsed=0
    local interval=10
    
    while [ $elapsed -lt $timeout ]; do
        local ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local total_pods=$PXC_NODES
        
        if [ "$ready_pods" -eq "$total_pods" ]; then
            log_success "All PXC pods are running!"
            break
        fi
        
        log_info "PXC pods ready: $ready_pods/$total_pods (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if [ $elapsed -ge $timeout ]; then
        log_error "Timeout waiting for PXC pods to be ready"
        exit 1
    fi
    
    # Wait for HAProxy pods
    log_info "Waiting for HAProxy pods to be ready..."
    kubectl wait --for=condition=ready --timeout=300s \
        pod -l app.kubernetes.io/component=haproxy \
        -n "$NAMESPACE"
    
    log_success "HAProxy pods are ready!"
}

# Display cluster information
display_info() {
    log_header "Installation Complete!"
    
    echo -e "${GREEN}✓${NC} Percona XtraDB Cluster ${PXC_VERSION} is running"
    echo -e "${GREEN}✓${NC} HAProxy ${HAPROXY_VERSION} is configured"
    echo -e "${GREEN}✓${NC} All components deployed to namespace: ${NAMESPACE}"
    echo ""
    
    log_info "Cluster Status:"
    kubectl get pods -n "$NAMESPACE" -o wide
    echo ""
    
    log_info "Services:"
    kubectl get svc -n "$NAMESPACE"
    echo ""
    
    log_info "Connection Information:"
    echo "  HAProxy Service: ${CLUSTER_NAME}-haproxy.${NAMESPACE}.svc.cluster.local:3306"
    echo "  PXC Nodes: ${CLUSTER_NAME}-pxc-0.${CLUSTER_NAME}-pxc.${NAMESPACE}.svc.cluster.local:3306"
    echo ""
    
    # Get root password
    local root_password=$(kubectl get secret "${CLUSTER_NAME}-secrets" -n "$NAMESPACE" -o jsonpath='{.data.root}' 2>/dev/null | base64 -d || echo "N/A")
    
    if [ "$root_password" != "N/A" ]; then
        log_info "Root Password (save this!):"
        echo "  $root_password"
        echo ""
    fi
    
    log_info "Useful Commands:"
    echo "  # Check cluster status"
    echo "  kubectl get pxc -n ${NAMESPACE}"
    echo ""
    echo "  # Connect to MySQL"
    echo "  kubectl exec -it ${CLUSTER_NAME}-pxc-0 -n ${NAMESPACE} -- mysql -uroot -p'${root_password}'"
    echo ""
    echo "  # View logs"
    echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=pxc"
    echo ""
    echo "  # Monitor backups"
    echo "  kubectl get pxc-backup -n ${NAMESPACE}"
    echo ""
    
    log_success "Installation completed successfully!"
}

# Main installation flow
main() {
    log_header "Percona XtraDB Cluster Installer for EKS"
    
    check_prerequisites
    prompt_configuration
    create_namespace
    install_operator
    create_s3_secret
    generate_helm_values
    install_cluster
    display_info
    
    # Cleanup temp files
    rm -f /tmp/pxc-values.yaml
}

# Run main function
main "$@"


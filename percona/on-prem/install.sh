#!/bin/bash
# Percona XtraDB Cluster Installation Script for On-Premise (vSphere/vCenter)
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
PXC_HAPROXY_SIZE="${PXC_HAPROXY_SIZE:-3}"  # Will be auto-adjusted based on resources
OPERATOR_VERSION="${OPERATOR_VERSION:-1.18.0}"
PXC_VERSION="${PXC_VERSION:-8.4.6}"  # XtraDB 8.4.6
STORAGE_CLASS=""  # Will prompt user for on-prem storage class

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

# Cross-platform base64 decode helper
decode_base64() {
    # macOS uses -D or -d, Linux/WSL uses -d or --decode
    if base64 --help 2>&1 | grep -q -- '--decode'; then
        base64 --decode
    else
        base64 -D
    fi
}

# Check prerequisites
check_prerequisites() {
    log_header "Checking Prerequisites"
    
    local missing=()
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    else
        log_success "kubectl found: $(kubectl --kubeconfig="$KUBECONFIG" version --client --short 2>/dev/null | head -n1 || echo 'installed')"
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        missing+=("helm")
    else
        log_success "helm found: $(helm version --short 2>/dev/null || echo 'installed')"
    fi
    
    # Verify Helm can access the cluster
    if command -v helm &> /dev/null; then
        if ! helm list -A &> /dev/null; then
            log_error "Helm cannot connect to Kubernetes cluster"
            log_error "Helm is trying to connect to: http://localhost:8080"
            echo ""
            log_info "Your kubectl is working, but Helm can't find the cluster."
            log_info "This usually means KUBECONFIG is not exported or Helm is not using it."
            echo ""
            log_info "To fix this, ensure KUBECONFIG is exported:"
            log_info "  export KUBECONFIG=\$KUBECONFIG"
            echo ""
            log_info "Or if using default location (~/.kube/config):"
            log_info "  export KUBECONFIG=~/.kube/config"
            echo ""
            log_info "Current KUBECONFIG: ${KUBECONFIG:-<not set>}"
            log_info "kubectl config: $(kubectl --kubeconfig="$KUBECONFIG" config view --minify -o jsonpath='{.current-context}' 2>/dev/null || echo '<unknown>')"
            echo ""
            exit 1
        fi
        log_success "Helm can access Kubernetes cluster"
    fi
    
    # Check bc for calculations
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    else
        log_success "bc found (for calculations)"
    fi
    
    # Check jq for JSON processing
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    else
        log_success "jq found (for JSON processing)"
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them and try again"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please configure kubectl and try again"
        exit 1
    fi
    
    log_success "Connected to Kubernetes cluster"
    
    # Display cluster info
    local cluster_version=$(kubectl --kubeconfig="$KUBECONFIG" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' 2>/dev/null || echo "")
    if [ -z "$cluster_version" ]; then
        cluster_version=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o json 2>/dev/null | jq -r '.items[0].status.nodeInfo.kubeletVersion // empty' 2>/dev/null || echo "unknown")
    fi
    log_info "Cluster version: $cluster_version"
}

# Detect node resources and calculate safe resource requests
detect_node_resources() {
    log_header "Analyzing Node Resources"
    
    # Get CPU capacity across all nodes
    local node_cpus=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o jsonpath='{.items[*].status.capacity.cpu}' 2>/dev/null | tr ' ' '\n' | head -1)
    local node_memory=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o jsonpath='{.items[*].status.capacity.memory}' 2>/dev/null | tr ' ' '\n' | head -1)
    
    if [ -z "$node_cpus" ] || [ -z "$node_memory" ]; then
        log_warn "Could not detect node resources"
        return
    fi
    
    # Convert memory to GB
    local mem_value=$(echo "$node_memory" | sed 's/[^0-9]//g')
    local node_memory_gb=$(echo "scale=1; $mem_value / 1024 / 1024" | bc)
    
    log_info "Node capacity detected:"
    log_info "  CPUs: ${node_cpus} vCPUs per node"
    log_info "  Memory: ${node_memory_gb} GB per node"
    
    # Calculate safe resource requests
    # Reserve 20% for system overhead + kube-system pods
    local usable_cpu=$(echo "scale=3; $node_cpus * 0.80" | bc)
    
    # For 3 PXC nodes + 3 HAProxy nodes, calculate per-pod CPU
    # Formula: (usable_cpu_per_node / pods_per_node) rounded down
    # Assuming even distribution: 6 pods across 3 nodes = 2 pods/node average
    local pxc_cpu_request=$(echo "scale=0; ($usable_cpu * 0.70) / 1" | bc)  # 70% for PXC
    local haproxy_cpu_request=$(echo "scale=0; ($usable_cpu * 0.15) * 1000 / 1" | bc)  # 15% for HAProxy in millicores
    
    # Ensure minimum values
    if [ $(echo "$pxc_cpu_request < 500" | bc) -eq 1 ]; then
        pxc_cpu_request=500
    fi
    if [ $(echo "$haproxy_cpu_request < 50" | bc) -eq 1 ]; then
        haproxy_cpu_request=50
    fi
    
    # Store recommended values
    RECOMMENDED_PXC_CPU="${pxc_cpu_request}m"
    RECOMMENDED_HAPROXY_CPU="${haproxy_cpu_request}m"
    
    log_info "Recommended resource requests:"
    log_info "  PXC CPU: ${RECOMMENDED_PXC_CPU}"
    log_info "  HAProxy CPU: ${RECOMMENDED_HAPROXY_CPU}"
    
    # Warn if nodes are very small
    if [ $(echo "$node_cpus < 2" | bc) -eq 1 ]; then
        log_warn "Nodes have limited CPU (${node_cpus} vCPUs)"
        log_warn "Consider using larger nodes for production workloads"
    fi
    
    if [ $(echo "$node_memory_gb < 6" | bc) -eq 1 ]; then
        log_warn "Nodes have limited memory (${node_memory_gb} GB)"
        log_warn "Maximum safe memory per PXC pod: ~$(echo "scale=0; $node_memory_gb * 0.5" | bc)Gi"
    fi
}

# Prompt for configuration
prompt_configuration() {
    log_header "Percona XtraDB Cluster Configuration"
    
    # Prompt for namespace
    read -p "Enter namespace name [default: percona]: " namespace_input
    NAMESPACE="${namespace_input:-percona}"
    
    echo ""
    echo -e "${CYAN}This script will install:${NC}"
    echo "  - Percona XtraDB Cluster ${PXC_VERSION}"
    echo "  - HAProxy (operator-managed version)"
    echo "  - Percona Operator ${OPERATOR_VERSION}"
    echo "  - All components in namespace: ${NAMESPACE}"
    echo "  - Environment: On-Premise vSphere/vCenter"
    echo ""
    
    # List available storage classes with details
    log_info "Available StorageClasses in cluster:"
    echo ""
    
    # Get storage class information with provisioner and default status
    local sc_info=$(kubectl --kubeconfig="$KUBECONFIG" get storageclass -o json 2>/dev/null | jq -r '.items[] | 
        "\(.metadata.name)|\(.provisioner)|\(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false")"' 2>/dev/null || echo "")
    
    if [ -n "$sc_info" ]; then
        printf "  %-30s %-50s %-10s\n" "NAME" "PROVISIONER" "DEFAULT"
        printf "  %-30s %-50s %-10s\n" "----" "-----------" "-------"
        while IFS='|' read -r name provisioner is_default; do
            printf "  %-30s %-50s %-10s\n" "$name" "$provisioner" "$is_default"
        done <<< "$sc_info"
    else
        echo "  (none found)"
    fi
    echo ""
    
    # Detect default storage class
    local default_sc=$(kubectl --kubeconfig="$KUBECONFIG" get storageclass -o json 2>/dev/null | jq -r '.items[] | 
        select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | 
        .metadata.name' 2>/dev/null | head -1 || echo "")
    
    # Prompt for storage class
    if [ -n "$default_sc" ]; then
        read -p "Enter StorageClass name [default: $default_sc]: " storage_class
        STORAGE_CLASS="${storage_class:-$default_sc}"
    else
        read -p "Enter StorageClass name: " storage_class
        STORAGE_CLASS="${storage_class}"
    fi
    
    # Verify storage class was provided
    if [ -z "$STORAGE_CLASS" ]; then
        log_error "StorageClass name is required"
        exit 1
    fi
    
    # Verify storage class exists
    if ! kubectl --kubeconfig="$KUBECONFIG" get storageclass "$STORAGE_CLASS" &> /dev/null; then
        log_warn "StorageClass '$STORAGE_CLASS' not found in cluster"
        read -p "Continue anyway? (yes/no): " confirm_sc
        if [[ "$confirm_sc" != "yes" ]]; then
            exit 0
        fi
    else
        log_success "StorageClass '$STORAGE_CLASS' verified"
    fi
    
    # Prompt for data directory size
    read -p "Enter data directory size per node (e.g., 50Gi, 100Gi) [default: 50Gi]: " data_size
    DATA_DIR_SIZE="${data_size:-50Gi}"
    
    # Validate size format
    if ! [[ "$DATA_DIR_SIZE" =~ ^[0-9]+[GM]i$ ]]; then
        log_error "Invalid size format. Use format like: 50Gi or 100Gi"
        exit 1
    fi
    
    # Prompt for max memory per node
    # Note: Adjust based on your node capacity (e.g., 5Gi for 8GB nodes)
    read -p "Enter max memory per node (e.g., 4Gi, 5Gi, 8Gi) [default: 5Gi]: " max_memory
    MAX_MEMORY="${max_memory:-5Gi}"
    
    # Validate memory format
    if ! [[ "$MAX_MEMORY" =~ ^[0-9]+[GM]i$ ]]; then
        log_error "Invalid memory format. Use format like: 4Gi or 8Gi"
        exit 1
    fi
    
    # Prompt for MinIO backup configuration
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  MinIO Backup Configuration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "Enter MinIO bucket name [default: percona-backups]: " minio_bucket
    MINIO_BUCKET="${minio_bucket:-percona-backups}"
    
    # Prompt for MinIO credentials secret source namespace
    read -p "Enter namespace containing 'minio-creds' secret [default: minio-operator]: " minio_secret_namespace
    MINIO_SECRET_NAMESPACE="${minio_secret_namespace:-minio-operator}"
    
    # Verify the secret exists in the source namespace
    if ! kubectl --kubeconfig="$KUBECONFIG" get secret minio-creds -n "$MINIO_SECRET_NAMESPACE" &> /dev/null; then
        log_error "Secret 'minio-creds' not found in namespace '$MINIO_SECRET_NAMESPACE'"
        log_info "Available namespaces with secrets:"
        kubectl --kubeconfig="$KUBECONFIG" get secrets --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name=="minio-creds") | "  - \(.metadata.namespace)"' 2>/dev/null || echo "  (none found)"
        echo ""
        read -p "Enter correct namespace: " minio_secret_namespace_retry
        MINIO_SECRET_NAMESPACE="${minio_secret_namespace_retry}"
        
        if [ -z "$MINIO_SECRET_NAMESPACE" ] || ! kubectl --kubeconfig="$KUBECONFIG" get secret minio-creds -n "$MINIO_SECRET_NAMESPACE" &> /dev/null; then
            log_error "Secret 'minio-creds' not found. Cannot proceed without MinIO credentials."
            exit 1
        fi
    fi
    
    log_success "Found 'minio-creds' secret in namespace: $MINIO_SECRET_NAMESPACE"
    echo ""
    
    # Prompt for PMM configuration
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  PMM (Percona Monitoring and Management) Configuration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "Enable PMM monitoring? (yes/no) [default: yes]: " enable_pmm
    ENABLE_PMM="${enable_pmm:-yes}"
    
    if [[ "$ENABLE_PMM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        ENABLE_PMM="true"
        PMM_SERVER_HOST="monitoring-service.pmm.svc.cluster.local"
        
        log_info "PMM client version 3.4.1 will be installed"
        log_success "PMM will be enabled with server host: $PMM_SERVER_HOST"
    else
        ENABLE_PMM="false"
        PMM_SERVER_HOST=""
        log_info "PMM monitoring will be disabled"
    fi
    echo ""
    
    # Validate CPU resources will fit
    if [ -n "$RECOMMENDED_PXC_CPU" ] && [ -n "$RECOMMENDED_HAPROXY_CPU" ]; then
        # Calculate total CPU requests for the cluster
        local pxc_cpu_m=$(echo "$RECOMMENDED_PXC_CPU" | sed 's/m//')
        local haproxy_cpu_m=$(echo "$RECOMMENDED_HAPROXY_CPU" | sed 's/m//')
        local total_cpu_per_node=$(echo "scale=0; ($pxc_cpu_m + $haproxy_cpu_m) * 2" | bc)  # 2 pods per node average
        
        # Get node CPU capacity
        local node_cpus=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o jsonpath='{.items[0].status.capacity.cpu}' 2>/dev/null)
        local node_cpu_m=$((node_cpus * 1000))
        local usable_cpu_m=$(echo "scale=0; $node_cpu_m * 0.80" | bc)  # 80% usable
        
        if [ $(echo "$total_cpu_per_node > $usable_cpu_m" | bc) -eq 1 ]; then
            log_warn "Configuration may not fit on nodes!"
            log_warn "  Estimated CPU per node: ${total_cpu_per_node}m"
            log_warn "  Available CPU per node: ${usable_cpu_m}m (after system overhead)"
            log_warn "This may cause pods to be stuck in 'Pending' state"
            echo ""
            log_info "Automatically reducing HAProxy instances from 3 to 2..."
            PXC_HAPROXY_SIZE=2
            
            # Recalculate with 2 HAProxy instances
            local new_total_cpu=$(echo "scale=0; $pxc_cpu_m + ($haproxy_cpu_m * 2)" | bc)
            log_info "New estimated CPU per node: ${new_total_cpu}m"
            
            if [ $(echo "$new_total_cpu > $usable_cpu_m" | bc) -eq 1 ]; then
                log_error "Even with 2 HAProxy instances, resources are insufficient!"
                log_info "Options:"
                log_info "  1. Use nodes with more CPU cores"
                log_info "  2. Reduce memory allocation"
                exit 1
            else
                log_success "Configuration will fit with 2 HAProxy instances"
            fi
        else
            # Resources are sufficient for full 3 HAProxy instances
            PXC_HAPROXY_SIZE=${PXC_NODES}
        fi
    else
        # No resource detection available, use default
        PXC_HAPROXY_SIZE=${PXC_NODES}
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
    echo "  - Environment: On-Premise vSphere/vCenter"
    echo "  - Namespace: ${NAMESPACE}"
    echo "  - Cluster Name: ${CLUSTER_NAME}"
    echo "  - PXC Nodes: ${PXC_NODES}"
    echo "  - HAProxy Instances: ${PXC_HAPROXY_SIZE}"
    echo "  - Data Directory Size: ${DATA_DIR_SIZE}"
    echo "  - Max Memory per Node: ${MAX_MEMORY}"
    echo "  - InnoDB Buffer Pool Size (70%): ${BUFFER_POOL_SIZE}"
    echo "  - Storage Class: ${STORAGE_CLASS}"
    echo "  - PXC Version: ${PXC_VERSION}"
    echo "  - HAProxy: Operator-managed version"
    echo "  - MinIO Bucket: ${MINIO_BUCKET}"
    echo "  - MinIO Secret Source: ${MINIO_SECRET_NAMESPACE}"
    if [ "$ENABLE_PMM" = "true" ]; then
        echo "  - PMM Client: 3.4.1 (enabled)"
        echo "  - PMM Server Host: ${PMM_SERVER_HOST}"
    else
        echo "  - PMM Client: Disabled"
    fi
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
    
    if kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace ${NAMESPACE} already exists"
    else
        kubectl --kubeconfig="$KUBECONFIG" create namespace "$NAMESPACE"
        log_success "Namespace ${NAMESPACE} created"
    fi
    
    # Label namespace for monitoring
    kubectl --kubeconfig="$KUBECONFIG" label namespace "$NAMESPACE" \
        "app.kubernetes.io/name=percona-xtradb-cluster" \
        "app.kubernetes.io/managed-by=percona-operator" \
        --overwrite
    
    log_success "Namespace labeled"
}

# Install Percona Operator
install_operator() {
    log_header "Installing Percona Operator ${OPERATOR_VERSION}"
    
    # Check for existing operator installations in other namespaces
    local existing_operators=$(helm list -A -o json 2>/dev/null | jq -r '.[] | select(.name | startswith("percona-operator")) | .namespace' 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo "")
    
    if [ -n "$existing_operators" ]; then
        log_info "Found existing Percona Operators in namespaces: $existing_operators"
        log_info "This is OK - each operator watches only its own namespace"
    fi
    
    # Use a unique release name per namespace to avoid ClusterRole conflicts
    local release_name="percona-operator-${NAMESPACE}"
    
    # Check if operator already exists in this namespace
    if helm list -n "$NAMESPACE" -o json 2>/dev/null | jq -e ".[] | select(.name == \"$release_name\")" &>/dev/null; then
        log_warn "Operator release '$release_name' already exists in namespace $NAMESPACE"
        log_info "Will upgrade the existing installation"
    fi
    
    # Add Percona Helm repo
    log_info "Adding Percona Helm repository..."
    helm repo add percona https://percona.github.io/percona-helm-charts/ --force-update
    helm repo update
    
    log_success "Helm repository updated"
    
    # Install operator with namespace-specific release name
    log_info "Installing Percona Operator via Helm (release: $release_name)..."
    helm upgrade --install "$release_name" \
        percona/pxc-operator \
        --version "$OPERATOR_VERSION" \
        --namespace "$NAMESPACE" \
        --set watchNamespace="$NAMESPACE" \
        --wait \
        --timeout 5m
    
    log_success "Percona Operator installed"
    
    # Wait for operator to be ready
    log_info "Waiting for operator to be ready..."
    
    # The deployment name is based on the release name
    local expected_deploy_name="${release_name}-pxc-operator"
    
    # Try to find the operator deployment with various possible names
    local deployment_found=false
    for deploy_name in "$expected_deploy_name" "pxc-operator" "percona-xtradb-cluster-operator" "${release_name}"; do
        if kubectl --kubeconfig="$KUBECONFIG" get deployment "$deploy_name" -n "$NAMESPACE" &> /dev/null; then
            log_info "Found operator deployment: $deploy_name"
            kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
                "deployment/$deploy_name" \
                -n "$NAMESPACE"
            deployment_found=true
            break
        fi
    done
    
    # If deployment not found by name, try by label
    if [ "$deployment_found" = false ]; then
        log_info "Trying to find operator by label..."
        for label in "app.kubernetes.io/name=pxc-operator" "app.kubernetes.io/name=percona-xtradb-cluster-operator"; do
            if kubectl --kubeconfig="$KUBECONFIG" get pods -l "$label" -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
                log_info "Found operator pods with label: $label"
                kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=ready --timeout=300s \
                    pod -l "$label" \
                    -n "$NAMESPACE"
                break
            fi
        done
    fi
    
    # Wait for webhook service to have endpoints (critical for PXC CRD validation)
    log_info "Waiting for operator webhook service to be ready..."
    local webhook_ready=false
    for i in {1..60}; do
        local endpoints=$(kubectl --kubeconfig="$KUBECONFIG" get endpoints percona-xtradb-cluster-operator -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        if [ -n "$endpoints" ]; then
            webhook_ready=true
            log_success "Operator webhook service is ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    
    if [ "$webhook_ready" = false ]; then
        log_error "Operator webhook service did not become ready in time"
        log_info "Check operator pod logs:"
        kubectl --kubeconfig="$KUBECONFIG" logs -n "$NAMESPACE" -l app.kubernetes.io/name=pxc-operator --tail=50
        exit 1
    fi
    
    # Additional wait to ensure webhook is fully initialized
    log_info "Waiting for webhook to fully initialize..."
    sleep 10
    
    log_success "Operator is ready"
}

# Copy MinIO credentials secret from source namespace
create_minio_secret() {
    log_header "Copying MinIO Credentials Secret"
    
    # Check if secret already exists in target namespace
    if kubectl --kubeconfig="$KUBECONFIG" get secret minio-creds -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret 'minio-creds' already exists in namespace '$NAMESPACE', skipping creation"
        return
    fi
    
    # Get the secret from source namespace and copy to target namespace
    log_info "Copying 'minio-creds' from namespace '$MINIO_SECRET_NAMESPACE' to '$NAMESPACE'..."
    
    if kubectl --kubeconfig="$KUBECONFIG" get secret minio-creds -n "$MINIO_SECRET_NAMESPACE" -o json | \
       jq 'del(.metadata.namespace,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.selfLink,.metadata.uid)' | \
       kubectl --kubeconfig="$KUBECONFIG" apply -n "$NAMESPACE" -f - &> /dev/null; then
        log_success "MinIO credentials secret 'minio-creds' copied successfully"
    else
        log_error "Failed to copy MinIO credentials secret"
        exit 1
    fi
}

# Create MinIO bucket
create_minio_bucket() {
    log_header "Creating MinIO Bucket"
    
    # Check if MinIO pod exists
    local minio_pod="myminio-pool-0-0"
    if ! kubectl --kubeconfig="$KUBECONFIG" get pod "$minio_pod" -n minio-operator &> /dev/null; then
        log_error "MinIO pod '$minio_pod' not found in namespace 'minio-operator'"
        log_error "Please ensure MinIO is installed before running this script"
        exit 1
    fi
    
    log_info "Extracting MinIO credentials from secret..."
    
    # Get credentials from the secret
    local access_key=$(kubectl --kubeconfig="$KUBECONFIG" get secret minio-creds -n "$MINIO_SECRET_NAMESPACE" -o jsonpath='{.data.accesskey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    local secret_key=$(kubectl --kubeconfig="$KUBECONFIG" get secret minio-creds -n "$MINIO_SECRET_NAMESPACE" -o jsonpath='{.data.secretkey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        log_error "Failed to extract credentials from 'minio-creds' secret"
        exit 1
    fi
    
    log_info "Setting up MinIO client alias in pod '$minio_pod'..."
    
    # Set up mc alias
    if ! kubectl --kubeconfig="$KUBECONFIG" -n minio-operator exec -it "$minio_pod" -- bash -c \
        "mc --insecure alias set local https://localhost:9000 $access_key $secret_key" 2>/dev/null; then
        log_error "Failed to set up MinIO client alias"
        exit 1
    fi
    
    log_success "MinIO client alias configured"
    
    # Check if bucket already exists
    log_info "Checking if bucket '$MINIO_BUCKET' already exists..."
    local bucket_exists=$(kubectl --kubeconfig="$KUBECONFIG" -n minio-operator exec -it "$minio_pod" -- bash -c \
        "mc --insecure ls local | grep -w '$MINIO_BUCKET'" 2>/dev/null || echo "")
    
    if [ -n "$bucket_exists" ]; then
        log_info "Bucket '$MINIO_BUCKET' already exists, using existing bucket"
    else
        # Create bucket
        log_info "Creating bucket '$MINIO_BUCKET'..."
        if kubectl --kubeconfig="$KUBECONFIG" -n minio-operator exec -it "$minio_pod" -- bash -c \
            "mc --insecure mb -p local/$MINIO_BUCKET" 2>/dev/null; then
            log_success "Bucket '$MINIO_BUCKET' created successfully"
        else
            log_error "Failed to create bucket '$MINIO_BUCKET'"
            exit 1
        fi
    fi
    
    # List buckets to verify
    log_info "Current MinIO buckets:"
    kubectl --kubeconfig="$KUBECONFIG" -n minio-operator exec -it "$minio_pod" -- bash -c \
        "mc --insecure ls local" 2>/dev/null | sed 's/^/  /' || log_warn "Could not list buckets"
    
    echo ""
}

# Generate Helm values
generate_helm_values() {
    log_header "Generating Helm Values"
    
    # Calculate HAProxy CPU limit (must be >= request)
    local haproxy_cpu_request_value=$(echo "${RECOMMENDED_HAPROXY_CPU:-100m}" | sed 's/m//')
    local haproxy_cpu_limit_value=$(echo "scale=0; $haproxy_cpu_request_value * 2" | bc)
    # Ensure minimum limit of 300m
    if [ $(echo "$haproxy_cpu_limit_value < 300" | bc) -eq 1 ]; then
        haproxy_cpu_limit_value=300
    fi
    local HAPROXY_CPU_LIMIT="${haproxy_cpu_limit_value}m"
    
    cat > /tmp/pxc-values.yaml <<EOF
# Percona XtraDB Cluster Configuration for On-Premise vSphere/vCenter
crVersion: ${PXC_VERSION}

pxc:
  size: ${PXC_NODES}
  image:
    repository: percona/percona-xtradb-cluster
    tag: ${PXC_VERSION}
  
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
      cpu: ${RECOMMENDED_PXC_CPU:-600m}
    limits:
      memory: ${MAX_MEMORY}
      cpu: 2
      
  persistence:
    enabled: true
    size: ${DATA_DIR_SIZE}
    storageClass: ${STORAGE_CLASS}
    
  # On-Premise host-based anti-affinity
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - pxc
        topologyKey: kubernetes.io/hostname
        
  podDisruptionBudget:
    maxUnavailable: 1

# HAProxy Configuration
haproxy:
  enabled: true
  size: ${PXC_HAPROXY_SIZE}
  
  resources:
    requests:
      memory: 128Mi
      cpu: ${RECOMMENDED_HAPROXY_CPU:-100m}
    limits:
      memory: 512Mi
      cpu: ${HAPROXY_CPU_LIMIT}
      
  # On-Premise host-based anti-affinity
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/component
            operator: In
            values:
            - haproxy
        topologyKey: kubernetes.io/hostname
        
  podDisruptionBudget:
    maxUnavailable: 1

# ProxySQL disabled (using HAProxy)
proxysql:
  enabled: false

# Backup configuration with MinIO
backup:
  enabled: true
  image:
    repository: percona/percona-xtrabackup
    tag: 8.0.35-33.1
  
  pitr:
    enabled: true
    storageName: minio
    timeBetweenUploads: 60
    
  storages:
    minio:
      type: s3
      verifyTLS: false
      s3:
        bucket: ${MINIO_BUCKET}
        region: us-east-1
        endpointUrl: https://myminio-hl.minio-operator.svc.cluster.local:9000
        credentialsSecret: minio-creds
        
  schedule:
    - name: "daily-full-backup"
      schedule: "0 2 * * *"
      keep: 7
      storageName: minio

# PMM Configuration
pmm:
  enabled: ${ENABLE_PMM}
  image:
    repository: percona/pmm-client
    tag: 3.4.1
  serverHost: "${PMM_SERVER_HOST}"
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
EOF
    
    log_success "Helm values generated at /tmp/pxc-values.yaml"
}

# Diagnose pod failures
diagnose_pod_failures() {
    local namespace="$1"
    local label_selector="$2"
    
    echo ""
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "  POD DIAGNOSTICS"
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Get all pods with the label
    local pods=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$namespace" -l "$label_selector" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pods" ]; then
        log_error "No pods found with label $label_selector in namespace $namespace"
        return
    fi
    
    # Show pod status summary
    log_info "Pod Status Summary:"
    kubectl --kubeconfig="$KUBECONFIG" get pods -n "$namespace" -l "$label_selector" 2>/dev/null || true
    echo ""
    
    # Check each pod individually
    while read -r line; do
        if [ -z "$line" ]; then
            continue
        fi
        
        local pod_name=$(echo "$line" | awk '{print $1}')
        local ready=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local restarts=$(echo "$line" | awk '{print $4}')
        
        # Check if pod has issues
        if [[ "$status" =~ CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|Pending|Init:Error|Init:CrashLoopBackOff ]]; then
            log_error "Pod $pod_name is in bad state: $status (Restarts: $restarts)"
            
            # Show pod events
            echo ""
            log_info "Recent events for $pod_name:"
            kubectl --kubeconfig="$KUBECONFIG" get events -n "$namespace" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
            echo ""
            
            # Show container statuses
            log_info "Container statuses for $pod_name:"
            kubectl --kubeconfig="$KUBECONFIG" get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r '.status.containerStatuses[]? | "  - \(.name): ready=\(.ready), restarts=\(.restartCount), state=\(.state | keys[0])"' 2>/dev/null || true
            echo ""
            
            # Get logs from failing containers
            local containers=$(kubectl --kubeconfig="$KUBECONFIG" get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
            for container in $containers; do
                # Check if container has terminated or is in waiting state
                local container_state=$(kubectl --kubeconfig="$KUBECONFIG" get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r ".status.containerStatuses[]? | select(.name==\"$container\") | .state | keys[0]" 2>/dev/null || echo "")
                
                if [ "$container_state" = "waiting" ] || [ "$container_state" = "terminated" ]; then
                    log_warn "Logs from container '$container' in pod '$pod_name':"
                    kubectl --kubeconfig="$KUBECONFIG" logs "$pod_name" -n "$namespace" -c "$container" --tail=30 2>/dev/null || \
                        kubectl --kubeconfig="$KUBECONFIG" logs "$pod_name" -n "$namespace" -c "$container" --previous --tail=30 2>/dev/null || \
                        log_error "  Cannot retrieve logs for container $container"
                    echo ""
                fi
            done
            
        elif [[ ! "$ready" =~ ^([0-9]+)/\1$ ]]; then
            # Pod is running but not all containers are ready
            log_warn "Pod $pod_name is running but not fully ready: $ready (Status: $status)"
            
            # Show which containers aren't ready
            log_info "Container statuses for $pod_name:"
            kubectl --kubeconfig="$KUBECONFIG" get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r '.status.containerStatuses[]? | "  - \(.name): ready=\(.ready), restarts=\(.restartCount), state=\(.state | keys[0])"' 2>/dev/null || true
            echo ""
            
            # Show recent events
            log_info "Recent events for $pod_name:"
            kubectl --kubeconfig="$KUBECONFIG" get events -n "$namespace" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || true
            echo ""
            
            # Get logs from non-ready containers
            local containers=$(kubectl --kubeconfig="$KUBECONFIG" get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
            for container in $containers; do
                local container_ready=$(kubectl --kubeconfig="$KUBECONFIG" get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r ".status.containerStatuses[]? | select(.name==\"$container\") | .ready" 2>/dev/null || echo "false")
                
                if [ "$container_ready" = "false" ]; then
                    log_warn "Logs from non-ready container '$container' in pod '$pod_name' (last 30 lines):"
                    kubectl --kubeconfig="$KUBECONFIG" logs "$pod_name" -n "$namespace" -c "$container" --tail=30 2>/dev/null || log_error "  Cannot retrieve logs"
                    echo ""
                fi
            done
        fi
    done <<< "$pods"
    
    # Check node resources
    echo ""
    log_info "Node Resource Status:"
    kubectl --kubeconfig="$KUBECONFIG" top nodes 2>/dev/null || log_warn "Cannot get node metrics (metrics-server may not be installed)"
    echo ""
    
    # Check for resource constraints
    log_info "Checking for resource constraints..."
    local resource_events=$(kubectl --kubeconfig="$KUBECONFIG" get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "insufficient\|failedscheduling\|outof" | tail -5 || echo "")
    if [ -n "$resource_events" ]; then
        # Check if these are recent (last 5 minutes) or historical
        local recent_events=$(kubectl --kubeconfig="$KUBECONFIG" get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | \
            awk -v now="$(date +%s)" '{
                # Try to parse the AGE column (e.g., "5m", "2h", "3d")
                age=$5; 
                if (age ~ /^[0-9]+s$/) seconds = substr(age,1,length(age)-1)
                else if (age ~ /^[0-9]+m$/) seconds = substr(age,1,length(age)-1) * 60
                else if (age ~ /^[0-9]+h$/) seconds = substr(age,1,length(age)-1) * 3600
                else seconds = 999999  # Old event
                if (seconds <= 300) print $0  # Last 5 minutes
            }' | grep -i "insufficient\|failedscheduling\|outof" || echo "")
        
        if [ -n "$recent_events" ]; then
            log_error "Found RECENT resource constraint events (last 5 minutes):"
            echo "$recent_events"
        else
            log_warn "Found resource constraint events (older than 5 minutes, likely resolved):"
            echo "$resource_events"
            log_info "These appear to be historical - pods eventually scheduled successfully"
        fi
    else
        log_success "No resource constraint events found"
    fi
    echo ""
    
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Install PXC Cluster
install_cluster() {
    log_header "Installing Percona XtraDB Cluster: ${CLUSTER_NAME}"
    
    # Check if release exists in a bad state
    local release_status=$(helm list -n "$NAMESPACE" --filter "^${CLUSTER_NAME}$" --output json 2>/dev/null | jq -r '.[0].status' 2>/dev/null || echo "")
    
    if [ "$release_status" = "failed" ] || [ "$release_status" = "pending-install" ] || [ "$release_status" = "pending-upgrade" ]; then
        log_warn "Found Helm release '${CLUSTER_NAME}' in bad state: $release_status"
        log_info "Cleaning up failed release..."
        helm uninstall "$CLUSTER_NAME" -n "$NAMESPACE" --wait --timeout 2m 2>/dev/null || true
        sleep 2
    fi
    
    # Clean up any orphaned PXC resources from previous failed installs
    if kubectl --kubeconfig="$KUBECONFIG" get pxc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_warn "Found orphaned PXC resources from previous install. Cleaning up..."
        
        # Remove finalizers
        kubectl --kubeconfig="$KUBECONFIG" get pxc -n "$NAMESPACE" -o name 2>/dev/null | xargs -r -I {} kubectl --kubeconfig="$KUBECONFIG" patch {} -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        
        # Force delete
        kubectl --kubeconfig="$KUBECONFIG" delete pxc --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        
        # Wait for deletion
        sleep 5
        log_success "Orphaned PXC resources cleaned up"
    fi
    
    log_info "Installing PXC cluster via Helm..."
    if ! helm upgrade --install "$CLUSTER_NAME" \
        percona/pxc-db \
        --namespace "$NAMESPACE" \
        --values /tmp/pxc-values.yaml \
        --wait \
        --timeout 15m; then
        
        log_error "Helm install failed. Checking for issues..."
        echo ""
        log_info "Recent events:"
        kubectl --kubeconfig="$KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
        echo ""
        log_info "Pod status:"
        kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE"
        exit 1
    fi
    
    log_success "PXC cluster Helm chart installed"
    
    # Wait for cluster to be ready
    log_info "Waiting for PXC pods to be ready (this may take several minutes)..."
    
    local timeout=900  # 15 minutes
    local elapsed=0
    local interval=10
    local last_diagnostic=0
    local diagnostic_interval=60  # Run diagnostics every 60s
    
    while [ $elapsed -lt $timeout ]; do
        # Check READY column properly - a pod is ready when READY shows N/N (e.g., "3/3")
        local ready_count=0
        local total_pods=$PXC_NODES
        
        # Get pod status with READY column
        local pod_status=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc --no-headers 2>/dev/null || echo "")
        
        if [ -n "$pod_status" ]; then
            # Count pods where READY column shows all containers ready (e.g., "3/3", "2/2")
            while read -r line; do
                if [ -n "$line" ]; then
                    local ready_col=$(echo "$line" | awk '{print $2}')
                    # Check if READY column is X/X where both numbers are equal and non-zero
                    if [[ "$ready_col" =~ ^([0-9]+)/([0-9]+)$ ]]; then
                        local ready="${BASH_REMATCH[1]}"
                        local total="${BASH_REMATCH[2]}"
                        if [ "$ready" -eq "$total" ] && [ "$ready" -gt 0 ]; then
                            ready_count=$((ready_count + 1))
                        fi
                    fi
                fi
            done <<< "$pod_status"
        fi
        
        if [ "$ready_count" -eq "$total_pods" ]; then
            log_success "All PXC pods are ready!"
            break
        fi
        
        log_info "PXC pods ready: $ready_count/$total_pods (${elapsed}s elapsed)"
        
        # Run diagnostics periodically if pods aren't ready
        if [ $((elapsed - last_diagnostic)) -ge $diagnostic_interval ] && [ $elapsed -gt 0 ]; then
            log_warn "Pods not ready after ${elapsed}s - running diagnostics..."
            diagnose_pod_failures "$NAMESPACE" "app.kubernetes.io/component=pxc"
            last_diagnostic=$elapsed
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if [ $elapsed -ge $timeout ]; then
        log_error "Timeout waiting for PXC pods to be ready after ${timeout}s"
        log_error "Running final diagnostics..."
        diagnose_pod_failures "$NAMESPACE" "app.kubernetes.io/component=pxc"
        exit 1
    fi
    
    # Wait for HAProxy pods
    log_info "Waiting for HAProxy pods to be ready..."
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=ready --timeout=300s \
        pod -l app.kubernetes.io/component=haproxy \
        -n "$NAMESPACE"
    
    log_success "HAProxy pods are ready!"
}

# Configure PITR environment variables
configure_pitr() {
    log_header "Configuring PITR"

    local pitr_deployment="${CLUSTER_NAME}-pxc-db-pitr"
    # Operator deployment name is based on release name (namespace-specific)
    local operator_deployment="percona-operator-${NAMESPACE}-pxc-operator"

    # Wait for PITR deployment to be created
    log_info "Waiting for PITR deployment..."
    local retries=0
    while [ $retries -lt 60 ]; do
        if kubectl --kubeconfig="$KUBECONFIG" get deployment "$pitr_deployment" -n "$NAMESPACE" &>/dev/null; then
            break
        fi
        sleep 5
        retries=$((retries + 1))
    done

    if ! kubectl --kubeconfig="$KUBECONFIG" get deployment "$pitr_deployment" -n "$NAMESPACE" &>/dev/null; then
        log_warn "PITR deployment not found after 5 minutes"
        return
    fi

    log_info "PITR deployment found, configuring GTID_CACHE_KEY..."

    # Setup trap to ensure operator is scaled back up on exit/error
    trap 'kubectl --kubeconfig="$KUBECONFIG" scale deployment "$operator_deployment" -n "$NAMESPACE" --replicas=1 &>/dev/null || true' EXIT ERR

    # Scale down operator to prevent reconciliation
    log_info "Temporarily scaling down operator..."
    if ! kubectl --kubeconfig="$KUBECONFIG" scale deployment "$operator_deployment" -n "$NAMESPACE" --replicas=0; then
        log_error "Failed to scale down operator"
        trap - EXIT ERR
        return 1
    fi
    sleep 5

    # Add GTID_CACHE_KEY environment variable using jq
    log_info "Adding GTID_CACHE_KEY to PITR deployment..."
    
    # Check if GTID_CACHE_KEY already exists
    local has_gtid_key=$(kubectl --kubeconfig="$KUBECONFIG" get deployment "$pitr_deployment" -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="GTID_CACHE_KEY") | .name' 2>/dev/null || echo "")
    
    if [ -n "$has_gtid_key" ]; then
        log_info "GTID_CACHE_KEY already exists in PITR deployment"
    else
        # Add the environment variable (handle null .env array)
        if kubectl --kubeconfig="$KUBECONFIG" get deployment "$pitr_deployment" -n "$NAMESPACE" -o json | \
           jq '.spec.template.spec.containers[0].env = (.spec.template.spec.containers[0].env // []) + [{"name":"GTID_CACHE_KEY","value":"pxc-pitr-cache"}]' | \
           kubectl --kubeconfig="$KUBECONFIG" replace -f - 2>&1 | tee /tmp/pitr-config.log | grep -q "replaced"; then
            log_success "GTID_CACHE_KEY added successfully"
        else
            log_error "Failed to add GTID_CACHE_KEY"
            log_error "Error details:"
            cat /tmp/pitr-config.log
            log_error "PITR will not function correctly - manual configuration required"
            trap - EXIT ERR
            return 1
        fi
    fi

    # Scale operator back up
    log_info "Scaling operator back up..."
    if ! kubectl --kubeconfig="$KUBECONFIG" scale deployment "$operator_deployment" -n "$NAMESPACE" --replicas=1; then
        log_error "Failed to scale operator back up - please run manually:"
        log_error "  kubectl scale deployment $operator_deployment -n $NAMESPACE --replicas=1"
        trap - EXIT ERR
        return 1
    fi

    # Clear trap
    trap - EXIT ERR

    # Wait for operator to be ready
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available deployment/"$operator_deployment" -n "$NAMESPACE" --timeout=60s &>/dev/null || true

    log_success "PITR configured with GTID cache key"
}

# Display cluster information
display_info() {
    log_header "Installation Complete!"
    
    # Get actual installed versions
    local actual_pxc_version=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc -o jsonpath='{.items[0].spec.containers[?(@.name=="pxc")].image}' 2>/dev/null | sed 's/.*://' || echo "${PXC_VERSION}")
    local actual_haproxy_version=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" -l app.kubernetes.io/component=haproxy -o jsonpath='{.items[0].spec.containers[?(@.name=="haproxy")].image}' 2>/dev/null | sed 's/.*://' || echo "operator-default")
    
    echo -e "${GREEN}✓${NC} Percona XtraDB Cluster ${actual_pxc_version} is running"
    echo -e "${GREEN}✓${NC} HAProxy ${actual_haproxy_version} is configured"
    echo -e "${GREEN}✓${NC} Percona Operator ${OPERATOR_VERSION}"
    
    # Show PMM status if enabled
    if [ "$ENABLE_PMM" = "true" ]; then
        local actual_pmm_version=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc -o jsonpath='{.items[0].spec.containers[?(@.name=="pmm-client")].image}' 2>/dev/null | sed 's/.*://' || echo "3.4.1")
        echo -e "${GREEN}✓${NC} PMM Client ${actual_pmm_version} is enabled"
        echo -e "${GREEN}✓${NC} PMM Server Host: ${PMM_SERVER_HOST}"
    fi
    
    echo -e "${GREEN}✓${NC} All components deployed to namespace: ${NAMESPACE}"
    echo -e "${GREEN}✓${NC} Environment: On-Premise vSphere/vCenter"
    echo ""
    
    log_info "Cluster Status:"
    kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" -o wide
    echo ""
    
    log_info "Services:"
    kubectl --kubeconfig="$KUBECONFIG" get svc -n "$NAMESPACE"
    echo ""
    
    log_info "Connection Information:"
    echo "  HAProxy Service: ${CLUSTER_NAME}-pxc-db-haproxy.${NAMESPACE}.svc.cluster.local:3306"
    echo "  PXC Nodes: ${CLUSTER_NAME}-pxc-db-pxc-0.${CLUSTER_NAME}-pxc-db-pxc.${NAMESPACE}.svc.cluster.local:3306"
    echo ""
    
    # Get root password
    local root_password=$(kubectl --kubeconfig="$KUBECONFIG" get secret "${CLUSTER_NAME}-pxc-db-secrets" -n "$NAMESPACE" -o jsonpath='{.data.root}' 2>/dev/null | decode_base64 2>/dev/null || echo "")
    
    if [ -n "$root_password" ]; then
        log_info "Root Password (save this!):"
        echo "  $root_password"
        echo ""
    fi
    
    log_info "Useful Commands:"
    echo "  # Check cluster status"
    echo "  kubectl get pxc -n ${NAMESPACE}"
    echo ""
    echo "  # Get root password"
    echo "  kubectl get secret ${CLUSTER_NAME}-pxc-db-secrets -n ${NAMESPACE} -o jsonpath='{.data.root}' | base64 -d && echo"
    echo ""
    echo "  # Connect to MySQL (via HAProxy)"
    echo "  kubectl exec -it ${CLUSTER_NAME}-pxc-db-haproxy-0 -n ${NAMESPACE} -c haproxy -- mysql -h127.0.0.1 -uroot -p\$(kubectl get secret ${CLUSTER_NAME}-pxc-db-secrets -n ${NAMESPACE} -o jsonpath='{.data.root}' | base64 -d)"
    echo ""
    echo "  # Connect directly to PXC pod"
    echo "  kubectl exec -it ${CLUSTER_NAME}-pxc-db-pxc-0 -n ${NAMESPACE} -c pxc -- mysql -uroot -p\$(kubectl get secret ${CLUSTER_NAME}-pxc-db-secrets -n ${NAMESPACE} -o jsonpath='{.data.root}' | base64 -d)"
    echo ""
    echo "  # View logs"
    echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=pxc -c pxc"
    echo ""
    echo "  # Monitor backups"
    echo "  kubectl get pxc-backup -n ${NAMESPACE}"
    echo ""
    
    # PMM-specific commands if enabled
    if [ "$ENABLE_PMM" = "true" ]; then
        echo "  # Check PMM client status"
        echo "  kubectl logs -n ${NAMESPACE} ${CLUSTER_NAME}-pxc-db-pxc-0 -c pmm-client"
        echo ""
        echo "  # PMM Server"
        echo "  Server Host: ${PMM_SERVER_HOST}"
        echo ""
    fi
    
    log_success "Installation completed successfully!"
}

# Main installation flow
main() {
    log_header "Percona XtraDB Cluster Installer for On-Premise vSphere/vCenter"
    
    check_prerequisites
    detect_node_resources
    prompt_configuration
    create_namespace
    install_operator
    create_minio_secret
    create_minio_bucket
    generate_helm_values
    install_cluster
    configure_pitr
    display_info
    
    # Cleanup temp files
    rm -f /tmp/pxc-values.yaml
}

# Run main function
main "$@"


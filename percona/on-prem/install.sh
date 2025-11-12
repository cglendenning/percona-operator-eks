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
OPERATOR_VERSION="${OPERATOR_VERSION:-1.15.0}"
PXC_VERSION="${PXC_VERSION:-8.4.6}"  # XtraDB 8.4.6
HAPROXY_VERSION="${HAPROXY_VERSION:-2.8.15}"  # HAProxy 2.8.15
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

# Detect node resources and calculate safe resource requests
detect_node_resources() {
    log_header "Analyzing Node Resources"
    
    # Get CPU capacity across all nodes
    local node_cpus=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.cpu}' 2>/dev/null | tr ' ' '\n' | head -1)
    local node_memory=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.memory}' 2>/dev/null | tr ' ' '\n' | head -1)
    
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
    log_info "  HAProxy CPU: ${RECOMMENDED_HAPROXY_CPU}m"
    
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
    
    # List available storage classes
    log_info "Available StorageClasses in cluster:"
    kubectl get storageclass --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none found)"
    echo ""
    
    # Prompt for storage class
    read -p "Enter StorageClass name [default: default]: " storage_class
    STORAGE_CLASS="${storage_class:-default}"
    
    # Verify storage class exists
    if ! kubectl get storageclass "$STORAGE_CLASS" &> /dev/null; then
        log_warn "StorageClass '$STORAGE_CLASS' not found, but continuing..."
        read -p "Continue anyway? (yes/no): " confirm_sc
        if [[ "$confirm_sc" != "yes" ]]; then
            exit 0
        fi
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
    
    # Validate CPU resources will fit
    if [ -n "$RECOMMENDED_PXC_CPU" ] && [ -n "$RECOMMENDED_HAPROXY_CPU" ]; then
        # Calculate total CPU requests for the cluster
        local pxc_cpu_m=$(echo "$RECOMMENDED_PXC_CPU" | sed 's/m//')
        local haproxy_cpu_m=$(echo "$RECOMMENDED_HAPROXY_CPU" | sed 's/m//')
        local total_cpu_per_node=$(echo "scale=0; ($pxc_cpu_m + $haproxy_cpu_m) * 2" | bc)  # 2 pods per node average
        
        # Get node CPU capacity
        local node_cpus=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}' 2>/dev/null)
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
    
    # Try to find the operator deployment with various possible names
    local deployment_found=false
    for deploy_name in "pxc-operator" "percona-xtradb-cluster-operator" "percona-operator-pxc-operator"; do
        if kubectl get deployment "$deploy_name" -n "$NAMESPACE" &> /dev/null; then
            log_info "Found operator deployment: $deploy_name"
            kubectl wait --for=condition=available --timeout=300s \
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
            if kubectl get pods -l "$label" -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
                log_info "Found operator pods with label: $label"
                kubectl wait --for=condition=ready --timeout=300s \
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
        local endpoints=$(kubectl get endpoints percona-xtradb-cluster-operator -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
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
        kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=pxc-operator --tail=50
        exit 1
    fi
    
    # Additional wait to ensure webhook is fully initialized
    log_info "Waiting for webhook to fully initialize..."
    sleep 10
    
    log_success "Operator is ready"
}

# Create MinIO credentials secret for backups
create_minio_secret() {
    log_header "Creating MinIO Credentials Secret"
    
    # Generate random credentials
    local minio_access_key="minioadmin"
    local minio_secret_key=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    
    # Check if secret already exists
    if kubectl get secret percona-backup-minio -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret percona-backup-minio already exists, skipping creation"
        return
    fi
    
    kubectl create secret generic percona-backup-minio \
        -n "$NAMESPACE" \
        --from-literal=AWS_ACCESS_KEY_ID="$minio_access_key" \
        --from-literal=AWS_SECRET_ACCESS_KEY="$minio_secret_key"
    
    log_success "MinIO credentials secret created"
    log_info "Access Key: $minio_access_key"
    log_info "Secret Key: $minio_secret_key"
}

# Generate Helm values
generate_helm_values() {
    log_header "Generating Helm Values"
    
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
      cpu: 300m
      
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
      s3:
        bucket: percona-backups
        region: us-east-1
        endpointUrl: http://minio.minio.svc.cluster.local:9000
        forcePathStyle: true
        credentialsSecret: percona-backup-minio
        
  schedule:
    - name: "daily-full-backup"
      schedule: "0 2 * * *"
      keep: 7
      storageName: minio

# PMM disabled for now (can be enabled later)
pmm:
  enabled: false
EOF
    
    log_success "Helm values generated at /tmp/pxc-values.yaml"
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
    if kubectl get pxc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        log_warn "Found orphaned PXC resources from previous install. Cleaning up..."
        
        # Remove finalizers
        kubectl get pxc -n "$NAMESPACE" -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        
        # Force delete
        kubectl delete pxc --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        
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
        kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
        echo ""
        log_info "Pod status:"
        kubectl get pods -n "$NAMESPACE"
        exit 1
    fi
    
    log_success "PXC cluster Helm chart installed"
    
    # Wait for cluster to be ready
    log_info "Waiting for PXC pods to be ready (this may take several minutes)..."
    
    local timeout=900  # 15 minutes
    local elapsed=0
    local interval=10
    
    while [ $elapsed -lt $timeout ]; do
        local ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
        # Ensure we have a single integer
        ready_pods=$(echo "$ready_pods" | tr -d '\n' | head -n1)
        local total_pods=$PXC_NODES
        
        # Validate ready_pods is a number
        if ! [[ "$ready_pods" =~ ^[0-9]+$ ]]; then
            ready_pods=0
        fi
        
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

# Configure PITR environment variables
configure_pitr() {
    log_header "Configuring PITR"

    local pitr_deployment="${CLUSTER_NAME}-pxc-db-pitr"
    local operator_deployment="percona-operator-pxc-operator"

    # Wait for PITR deployment to be created
    log_info "Waiting for PITR deployment..."
    local retries=0
    while [ $retries -lt 60 ]; do
        if kubectl get deployment "$pitr_deployment" -n "$NAMESPACE" &>/dev/null; then
            break
        fi
        sleep 5
        retries=$((retries + 1))
    done

    if ! kubectl get deployment "$pitr_deployment" -n "$NAMESPACE" &>/dev/null; then
        log_warn "PITR deployment not found after 5 minutes"
        return
    fi

    log_info "PITR deployment found, configuring GTID_CACHE_KEY..."

    # Setup trap to ensure operator is scaled back up on exit/error
    trap 'kubectl scale deployment "$operator_deployment" -n "$NAMESPACE" --replicas=1 &>/dev/null || true' EXIT ERR

    # Scale down operator to prevent reconciliation
    log_info "Temporarily scaling down operator..."
    if ! kubectl scale deployment "$operator_deployment" -n "$NAMESPACE" --replicas=0; then
        log_error "Failed to scale down operator"
        trap - EXIT ERR
        return 1
    fi
    sleep 5

    # Add GTID_CACHE_KEY environment variable using jq
    log_info "Adding GTID_CACHE_KEY to PITR deployment..."
    if kubectl get deployment "$pitr_deployment" -n "$NAMESPACE" -o json | \
       jq '.spec.template.spec.containers[0].env += [{"name":"GTID_CACHE_KEY","value":"pxc-pitr-cache"}]' | \
       kubectl replace -f - &>/dev/null; then
        log_success "GTID_CACHE_KEY added successfully"
    else
        log_error "Failed to add GTID_CACHE_KEY"
        log_error "PITR will not function correctly - manual configuration required"
        trap - EXIT ERR
        return 1
    fi

    # Scale operator back up
    log_info "Scaling operator back up..."
    if ! kubectl scale deployment "$operator_deployment" -n "$NAMESPACE" --replicas=1; then
        log_error "Failed to scale operator back up - please run manually:"
        log_error "  kubectl scale deployment $operator_deployment -n $NAMESPACE --replicas=1"
        trap - EXIT ERR
        return 1
    fi

    # Clear trap
    trap - EXIT ERR

    # Wait for operator to be ready
    kubectl wait --for=condition=available deployment/"$operator_deployment" -n "$NAMESPACE" --timeout=60s &>/dev/null || true

    log_success "PITR configured with GTID cache key"
}

# Display cluster information
display_info() {
    log_header "Installation Complete!"
    
    echo -e "${GREEN}✓${NC} Percona XtraDB Cluster ${PXC_VERSION} is running"
    echo -e "${GREEN}✓${NC} HAProxy ${HAPROXY_VERSION} is configured"
    echo -e "${GREEN}✓${NC} All components deployed to namespace: ${NAMESPACE}"
    echo -e "${GREEN}✓${NC} Environment: On-Premise vSphere/vCenter"
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
    log_header "Percona XtraDB Cluster Installer for On-Premise vSphere/vCenter"
    
    check_prerequisites
    detect_node_resources
    prompt_configuration
    create_namespace
    install_operator
    create_minio_secret
    generate_helm_values
    install_cluster
    configure_pitr
    display_info
    
    # Cleanup temp files
    rm -f /tmp/pxc-values.yaml
}

# Run main function
main "$@"


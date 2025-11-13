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
    local cluster_version=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' 2>/dev/null || echo "")
    if [ -z "$cluster_version" ]; then
        cluster_version=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[0].status.nodeInfo.kubeletVersion // empty' 2>/dev/null || echo "unknown")
    fi
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
    local sc_info=$(kubectl get storageclass -o json 2>/dev/null | jq -r '.items[] | 
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
    local default_sc=$(kubectl get storageclass -o json 2>/dev/null | jq -r '.items[] | 
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
    if ! kubectl get storageclass "$STORAGE_CLASS" &> /dev/null; then
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
    
    # Check for existing operator installations in other namespaces
    local existing_operator=$(helm list -A --filter "percona-operator" -o json 2>/dev/null | jq -r '.[0].namespace // empty' 2>/dev/null || echo "")
    
    if [ -n "$existing_operator" ] && [ "$existing_operator" != "$NAMESPACE" ]; then
        log_error "Found existing Percona Operator in namespace: $existing_operator"
        log_error "The Percona Operator uses cluster-wide resources that conflict across namespaces."
        echo ""
        log_info "Please run the uninstall script first:"
        log_info "  cd $(dirname "$SCRIPT_DIR")"
        log_info "  ./percona/on-prem/uninstall.sh"
        echo ""
        log_info "Then re-run this installation script."
        exit 1
    fi
    
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
    local pods=$(kubectl get pods -n "$namespace" -l "$label_selector" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pods" ]; then
        log_error "No pods found with label $label_selector in namespace $namespace"
        return
    fi
    
    # Show pod status summary
    log_info "Pod Status Summary:"
    kubectl get pods -n "$namespace" -l "$label_selector" 2>/dev/null || true
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
            kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
            echo ""
            
            # Show container statuses
            log_info "Container statuses for $pod_name:"
            kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r '.status.containerStatuses[]? | "  - \(.name): ready=\(.ready), restarts=\(.restartCount), state=\(.state | keys[0])"' 2>/dev/null || true
            echo ""
            
            # Get logs from failing containers
            local containers=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
            for container in $containers; do
                # Check if container has terminated or is in waiting state
                local container_state=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r ".status.containerStatuses[]? | select(.name==\"$container\") | .state | keys[0]" 2>/dev/null || echo "")
                
                if [ "$container_state" = "waiting" ] || [ "$container_state" = "terminated" ]; then
                    log_warn "Logs from container '$container' in pod '$pod_name':"
                    kubectl logs "$pod_name" -n "$namespace" -c "$container" --tail=30 2>/dev/null || \
                        kubectl logs "$pod_name" -n "$namespace" -c "$container" --previous --tail=30 2>/dev/null || \
                        log_error "  Cannot retrieve logs for container $container"
                    echo ""
                fi
            done
            
        elif [[ ! "$ready" =~ ^([0-9]+)/\1$ ]]; then
            # Pod is running but not all containers are ready
            log_warn "Pod $pod_name is running but not fully ready: $ready (Status: $status)"
            
            # Show which containers aren't ready
            log_info "Container statuses for $pod_name:"
            kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r '.status.containerStatuses[]? | "  - \(.name): ready=\(.ready), restarts=\(.restartCount), state=\(.state | keys[0])"' 2>/dev/null || true
            echo ""
            
            # Show recent events
            log_info "Recent events for $pod_name:"
            kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || true
            echo ""
            
            # Get logs from non-ready containers
            local containers=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
            for container in $containers; do
                local container_ready=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r ".status.containerStatuses[]? | select(.name==\"$container\") | .ready" 2>/dev/null || echo "false")
                
                if [ "$container_ready" = "false" ]; then
                    log_warn "Logs from non-ready container '$container' in pod '$pod_name' (last 30 lines):"
                    kubectl logs "$pod_name" -n "$namespace" -c "$container" --tail=30 2>/dev/null || log_error "  Cannot retrieve logs"
                    echo ""
                fi
            done
        fi
    done <<< "$pods"
    
    # Check node resources
    echo ""
    log_info "Node Resource Status:"
    kubectl top nodes 2>/dev/null || log_warn "Cannot get node metrics (metrics-server may not be installed)"
    echo ""
    
    # Check for resource constraints
    log_info "Checking for resource constraints..."
    local resource_events=$(kubectl get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "insufficient\|failedscheduling\|outof" | tail -5 || echo "")
    if [ -n "$resource_events" ]; then
        log_error "Found resource constraint events:"
        echo "$resource_events"
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
    local last_diagnostic=0
    local diagnostic_interval=60  # Run diagnostics every 60s
    
    while [ $elapsed -lt $timeout ]; do
        # Check READY column properly - a pod is ready when READY shows N/N (e.g., "3/3")
        local ready_count=0
        local total_pods=$PXC_NODES
        
        # Get pod status with READY column
        local pod_status=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc --no-headers 2>/dev/null || echo "")
        
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
    
    # Check if GTID_CACHE_KEY already exists
    local has_gtid_key=$(kubectl get deployment "$pitr_deployment" -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="GTID_CACHE_KEY") | .name' 2>/dev/null || echo "")
    
    if [ -n "$has_gtid_key" ]; then
        log_info "GTID_CACHE_KEY already exists in PITR deployment"
    else
        # Add the environment variable (handle null .env array)
        if kubectl get deployment "$pitr_deployment" -n "$NAMESPACE" -o json | \
           jq '.spec.template.spec.containers[0].env = (.spec.template.spec.containers[0].env // []) + [{"name":"GTID_CACHE_KEY","value":"pxc-pitr-cache"}]' | \
           kubectl replace -f - 2>&1 | tee /tmp/pitr-config.log | grep -q "replaced"; then
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
    
    # Get actual installed versions
    local actual_pxc_version=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=pxc -o jsonpath='{.items[0].spec.containers[?(@.name=="pxc")].image}' 2>/dev/null | sed 's/.*://' || echo "${PXC_VERSION}")
    local actual_haproxy_version=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=haproxy -o jsonpath='{.items[0].spec.containers[?(@.name=="haproxy")].image}' 2>/dev/null | sed 's/.*://' || echo "operator-default")
    
    echo -e "${GREEN}✓${NC} Percona XtraDB Cluster ${actual_pxc_version} is running"
    echo -e "${GREEN}✓${NC} HAProxy ${actual_haproxy_version} is configured"
    echo -e "${GREEN}✓${NC} Percona Operator ${OPERATOR_VERSION}"
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
    echo "  HAProxy Service: ${CLUSTER_NAME}-pxc-db-haproxy.${NAMESPACE}.svc.cluster.local:3306"
    echo "  PXC Nodes: ${CLUSTER_NAME}-pxc-db-pxc-0.${CLUSTER_NAME}-pxc-db-pxc.${NAMESPACE}.svc.cluster.local:3306"
    echo ""
    
    # Get root password
    local root_password=$(kubectl get secret "${CLUSTER_NAME}-pxc-db-secrets" -n "$NAMESPACE" -o jsonpath='{.data.root}' 2>/dev/null | decode_base64 2>/dev/null || echo "")
    
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


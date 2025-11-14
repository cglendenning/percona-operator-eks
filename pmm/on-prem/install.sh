#!/bin/bash
# PMM v3 Server Installation Script for On-Premise Kubernetes
# Deploys Percona Monitoring and Management Server v3 in Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PMM_NAMESPACE="pmm"
PMM_VERSION="3"
PMM_IMAGE="percona/pmm-server:${PMM_VERSION}"
STORAGE_CLASS=""
STORAGE_SIZE="100Gi"
SERVICE_TYPE="NodePort"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

log_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_header "Checking Prerequisites"
    
    local missing=()
    if ! command -v kubectl &> /dev/null; then missing+=("kubectl"); fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them and try again."
        exit 1
    fi
    log_success "kubectl found"
    
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Prompt for configuration
prompt_configuration() {
    log_header "Configuration"
    
    # Storage class selection
    log_info "Available StorageClasses in cluster:"
    echo ""
    kubectl --kubeconfig="$KUBECONFIG" get storageclass --no-headers -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class" 2>/dev/null || {
        log_warn "Could not list storage classes"
    }
    echo ""
    
    # Detect default storage class
    local default_sc=$(kubectl --kubeconfig="$KUBECONFIG" get storageclass -o json 2>/dev/null | \
        jq -r '.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class" == "true") | .metadata.name' | head -1)
    
    if [ -z "$default_sc" ]; then
        read -p "Enter StorageClass name: " storage_class
    else
        read -p "Enter StorageClass name [default: $default_sc]: " storage_class
        storage_class="${storage_class:-$default_sc}"
    fi
    
    STORAGE_CLASS="$storage_class"
    
    if [ -z "$STORAGE_CLASS" ]; then
        log_error "StorageClass is required"
        exit 1
    fi
    
    # Verify storage class exists
    if ! kubectl --kubeconfig="$KUBECONFIG" get storageclass "$STORAGE_CLASS" &>/dev/null; then
        log_error "StorageClass '$STORAGE_CLASS' not found"
        exit 1
    fi
    
    log_success "Using StorageClass: $STORAGE_CLASS"
    echo ""
    
    # Storage size
    read -p "Enter storage size [default: ${STORAGE_SIZE}]: " storage_size
    STORAGE_SIZE="${storage_size:-$STORAGE_SIZE}"
    log_success "Storage size: $STORAGE_SIZE"
    echo ""
}

# Create namespace
create_namespace() {
    log_header "Creating PMM Namespace"
    
    if kubectl --kubeconfig="$KUBECONFIG" get namespace "$PMM_NAMESPACE" &>/dev/null; then
        log_warn "Namespace '$PMM_NAMESPACE' already exists"
    else
        kubectl --kubeconfig="$KUBECONFIG" create namespace "$PMM_NAMESPACE"
        log_success "Namespace '$PMM_NAMESPACE' created"
    fi
}

# Deploy PMM Server
deploy_pmm_server() {
    log_header "Deploying PMM Server v${PMM_VERSION}"
    
    log_info "Creating PMM Server StatefulSet..."
    
    cat <<EOF | kubectl --kubeconfig="$KUBECONFIG" apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pmm-server
  namespace: ${PMM_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pmm-server-data
  namespace: ${PMM_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pmm-server
  namespace: ${PMM_NAMESPACE}
  labels:
    app: pmm-server
spec:
  serviceName: pmm-server
  replicas: 1
  selector:
    matchLabels:
      app: pmm-server
  template:
    metadata:
      labels:
        app: pmm-server
    spec:
      serviceAccountName: pmm-server
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 0
      containers:
      - name: pmm-server
        image: ${PMM_IMAGE}
        ports:
        - containerPort: 80
          name: http
        - containerPort: 443
          name: https
        env:
        - name: DISABLE_TELEMETRY
          value: "1"
        - name: DISABLE_UPDATES
          value: "0"
        volumeMounts:
        - name: pmm-data
          mountPath: /srv
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 2000m
            memory: 4Gi
        livenessProbe:
          httpGet:
            path: /v1/readyz
            port: 80
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /v1/readyz
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
      volumes:
      - name: pmm-data
        persistentVolumeClaim:
          claimName: pmm-server-data
---
apiVersion: v1
kind: Service
metadata:
  name: monitoring-service
  namespace: ${PMM_NAMESPACE}
  labels:
    app: pmm-server
spec:
  type: ${SERVICE_TYPE}
  selector:
    app: pmm-server
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
  - name: https
    port: 443
    targetPort: 443
    protocol: TCP
EOF
    
    log_success "PMM Server resources created"
}

# Wait for PMM Server to be ready
wait_for_pmm_ready() {
    log_header "Waiting for PMM Server to be Ready"
    
    log_info "Waiting for PMM Server pod to start..."
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=ready pod -l app=pmm-server -n "$PMM_NAMESPACE" --timeout=600s || {
        log_error "PMM Server pod did not become ready in time"
        log_info "Checking pod status:"
        kubectl --kubeconfig="$KUBECONFIG" get pods -n "$PMM_NAMESPACE"
        log_info "Checking pod events:"
        kubectl --kubeconfig="$KUBECONFIG" get events -n "$PMM_NAMESPACE" --sort-by='.lastTimestamp'
        exit 1
    }
    
    log_success "PMM Server pod is ready"
}

# Create service account token for PMM v3
create_service_account_token() {
    log_header "Creating Service Account Token for PMM v3"
    
    log_info "PMM v3 uses service account tokens for authentication"
    
    # Create a secret for the service account token
    cat <<EOF | kubectl --kubeconfig="$KUBECONFIG" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: pmm-server-token
  namespace: ${PMM_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: pmm-server
type: kubernetes.io/service-account-token
EOF
    
    # Wait for token to be populated
    log_info "Waiting for token to be generated..."
    for i in {1..30}; do
        TOKEN=$(kubectl --kubeconfig="$KUBECONFIG" get secret pmm-server-token -n "$PMM_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
            log_success "Service account token created"
            return 0
        fi
        sleep 1
    done
    
    log_error "Failed to generate service account token"
    return 1
}

# Get PMM Server access information
get_access_info() {
    log_header "PMM Server Access Information"
    
    # Get NodePort information
    local http_nodeport=$(kubectl --kubeconfig="$KUBECONFIG" get svc monitoring-service -n "$PMM_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "")
    local https_nodeport=$(kubectl --kubeconfig="$KUBECONFIG" get svc monitoring-service -n "$PMM_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "")
    
    # Get node IPs
    local node_ips=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | tr ' ' '\n' | head -3)
    
    # Get service account token
    local token=$(kubectl --kubeconfig="$KUBECONFIG" get secret pmm-server-token -n "$PMM_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  PMM Server v${PMM_VERSION} Installation Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}PMM Server Access:${NC}"
    echo "  Service Type: NodePort"
    if [ -n "$https_nodeport" ]; then
        echo "  HTTPS Port: $https_nodeport"
    fi
    if [ -n "$http_nodeport" ]; then
        echo "  HTTP Port: $http_nodeport"
    fi
    echo ""
    echo "  Access PMM via any node IP:"
    echo "$node_ips" | while read -r ip; do
        if [ -n "$https_nodeport" ]; then
            echo "    https://$ip:$https_nodeport"
        fi
    done
    echo ""
    echo -e "${BLUE}Default Credentials:${NC}"
    echo "  Username: admin"
    echo "  Password: admin"
    echo "  ${YELLOW}(Change password on first login!)${NC}"
    echo ""
    echo -e "${BLUE}Service Account Token (for PMM v3):${NC}"
    if [ -n "$token" ]; then
        echo "  $token"
        echo ""
        echo "  ${YELLOW}Save this token! You'll need it to configure PMM clients.${NC}"
    else
        echo "  ${YELLOW}Token not yet available. Retrieve it with:${NC}"
        echo "  kubectl get secret pmm-server-token -n $PMM_NAMESPACE -o jsonpath='{.data.token}' | base64 -d"
    fi
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  # Check PMM Server status"
    echo "  kubectl get pods -n $PMM_NAMESPACE"
    echo ""
    echo "  # View PMM Server logs"
    echo "  kubectl logs -n $PMM_NAMESPACE -l app=pmm-server -f"
    echo ""
    echo "  # Get NodePort access information"
    echo "  kubectl get svc monitoring-service -n $PMM_NAMESPACE"
    echo ""
    echo "  # Get node IPs"
    echo "  kubectl get nodes -o wide"
    echo ""
    echo "  # Get service account token"
    echo "  kubectl get secret pmm-server-token -n $PMM_NAMESPACE -o jsonpath='{.data.token}' | base64 -d && echo"
    echo ""
    log_success "Installation completed successfully!"
}

# Main installation flow
main() {
    log_header "PMM Server v${PMM_VERSION} Installer for On-Premise Kubernetes"
    
    echo "This script will install:"
    echo "  - PMM Server version: ${PMM_VERSION}"
    echo "  - Namespace: ${PMM_NAMESPACE}"
    echo "  - Service Type: ${SERVICE_TYPE}"
    echo ""
    
    check_prerequisites
    prompt_configuration
    
    echo ""
    log_info "Installation Summary:"
    echo "  Namespace: ${PMM_NAMESPACE}"
    echo "  PMM Version: ${PMM_VERSION}"
    echo "  Storage Class: ${STORAGE_CLASS}"
    echo "  Storage Size: ${STORAGE_SIZE}"
    echo "  Service Type: ${SERVICE_TYPE}"
    echo ""
    
    read -p "Continue with installation? (yes/no) [yes]: " confirm
    confirm="${confirm:-yes}"
    if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
    
    create_namespace
    deploy_pmm_server
    wait_for_pmm_ready
    create_service_account_token
    get_access_info
}

# Run main installation
main


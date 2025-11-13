#!/bin/bash
# PMM v3 Server Installation Script for EKS
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
STORAGE_CLASS="gp3"
STORAGE_SIZE="100Gi"
SERVICE_TYPE="LoadBalancer"

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
    if ! command -v aws &> /dev/null; then missing+=("aws"); fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them and try again."
        exit 1
    fi
    log_success "kubectl and aws CLI found"
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
    
    # Verify EKS cluster
    local cluster_name=$(kubectl config current-context | grep -o 'percona-eks' || echo "")
    if [ -n "$cluster_name" ]; then
        log_success "Connected to EKS cluster: $cluster_name"
    else
        log_warn "Not connected to 'percona-eks' cluster. Proceeding anyway..."
    fi
}

# Create namespace
create_namespace() {
    log_header "Creating PMM Namespace"
    
    if kubectl get namespace "$PMM_NAMESPACE" &>/dev/null; then
        log_warn "Namespace '$PMM_NAMESPACE' already exists"
    else
        kubectl create namespace "$PMM_NAMESPACE"
        log_success "Namespace '$PMM_NAMESPACE' created"
    fi
}

# Deploy PMM Server
deploy_pmm_server() {
    log_header "Deploying PMM Server v${PMM_VERSION}"
    
    log_info "Creating PMM Server StatefulSet..."
    
    cat <<EOF | kubectl apply -f -
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
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
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
    kubectl wait --for=condition=ready pod -l app=pmm-server -n "$PMM_NAMESPACE" --timeout=600s || {
        log_error "PMM Server pod did not become ready in time"
        log_info "Checking pod status:"
        kubectl get pods -n "$PMM_NAMESPACE"
        log_info "Checking pod events:"
        kubectl get events -n "$PMM_NAMESPACE" --sort-by='.lastTimestamp'
        exit 1
    }
    
    log_success "PMM Server pod is ready"
}

# Create service account token for PMM v3
create_service_account_token() {
    log_header "Creating Service Account Token for PMM v3"
    
    log_info "PMM v3 uses service account tokens for authentication"
    
    # Create a secret for the service account token
    cat <<EOF | kubectl apply -f -
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
        TOKEN=$(kubectl get secret pmm-server-token -n "$PMM_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || echo "")
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
    
    log_info "Waiting for LoadBalancer to get external IP..."
    local lb_hostname=""
    for i in {1..60}; do
        lb_hostname=$(kubectl get svc monitoring-service -n "$PMM_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$lb_hostname" ]; then
            break
        fi
        sleep 5
    done
    
    if [ -z "$lb_hostname" ]; then
        log_warn "LoadBalancer external hostname not yet available"
        log_info "Run this command to check status:"
        echo "  kubectl get svc monitoring-service -n $PMM_NAMESPACE"
        echo ""
        lb_hostname="<pending>"
    else
        log_success "PMM Server is accessible via LoadBalancer"
    fi
    
    # Get service account token
    local token=$(kubectl get secret pmm-server-token -n "$PMM_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  PMM Server v${PMM_VERSION} Installation Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}PMM Server URL:${NC}"
    echo "  https://$lb_hostname"
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
    echo "  # Get LoadBalancer URL"
    echo "  kubectl get svc monitoring-service -n $PMM_NAMESPACE"
    echo ""
    echo "  # Get service account token"
    echo "  kubectl get secret pmm-server-token -n $PMM_NAMESPACE -o jsonpath='{.data.token}' | base64 -d && echo"
    echo ""
    log_success "Installation completed successfully!"
}

# Main installation flow
main() {
    log_header "PMM Server v${PMM_VERSION} Installer for EKS"
    
    echo "This script will install:"
    echo "  - PMM Server version: ${PMM_VERSION}"
    echo "  - Namespace: ${PMM_NAMESPACE}"
    echo "  - Storage: ${STORAGE_SIZE} on ${STORAGE_CLASS}"
    echo "  - Service Type: ${SERVICE_TYPE}"
    echo ""
    
    check_prerequisites
    create_namespace
    deploy_pmm_server
    wait_for_pmm_ready
    create_service_account_token
    get_access_info
}

# Run main installation
main


#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   DB Concierge Operator Installation${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found. Please install kubectl first.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster. Please check your kubeconfig.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ kubectl found and cluster accessible${NC}"

# Check if user has cluster-admin rights
if ! kubectl auth can-i create clusterroles &> /dev/null; then
    echo -e "${YELLOW}Warning: You may not have sufficient permissions to install cluster-scoped resources.${NC}"
    echo -e "${YELLOW}Installation may fail. Consider running with cluster-admin privileges.${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 1: Install CRD
echo ""
echo -e "${BLUE}[1/6] Installing AppDatabase CRD...${NC}"
kubectl apply -f "${SCRIPT_DIR}/crds/appdatabase-crd.yaml"
echo -e "${GREEN}✓ CRD installed${NC}"

# Step 2: Create namespace
echo ""
echo -e "${BLUE}[2/6] Creating db-concierge namespace...${NC}"
if kubectl get namespace db-concierge &> /dev/null; then
    echo -e "${YELLOW}Namespace db-concierge already exists, skipping${NC}"
else
    kubectl apply -f "${SCRIPT_DIR}/deploy/namespace.yaml"
    echo -e "${GREEN}✓ Namespace created${NC}"
fi

# Step 3: Create RBAC
echo ""
echo -e "${BLUE}[3/6] Creating RBAC resources...${NC}"
kubectl apply -f "${SCRIPT_DIR}/deploy/serviceaccount.yaml"
kubectl apply -f "${SCRIPT_DIR}/deploy/clusterrole.yaml"
kubectl apply -f "${SCRIPT_DIR}/deploy/clusterrolebinding.yaml"
echo -e "${GREEN}✓ RBAC resources created${NC}"

# Step 4: Create MySQL admin credentials secret
echo ""
echo -e "${BLUE}[4/6] Configuring MySQL admin credentials...${NC}"

if kubectl get secret db-concierge-mysql-admin -n db-concierge &> /dev/null; then
    echo -e "${YELLOW}Secret db-concierge-mysql-admin already exists.${NC}"
    read -p "Update it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        UPDATE_SECRET=true
    else
        UPDATE_SECRET=false
        echo -e "${YELLOW}Keeping existing secret${NC}"
    fi
else
    UPDATE_SECRET=true
fi

if [ "$UPDATE_SECRET" = true ]; then
    echo ""
    echo -e "${YELLOW}Please provide your PXC cluster admin credentials:${NC}"
    echo -e "${YELLOW}(These will be stored securely in a Kubernetes secret)${NC}"
    echo ""
    
    read -p "MySQL Admin Host [cluster1-haproxy.default.svc.cluster.local]: " MYSQL_HOST
    MYSQL_HOST=${MYSQL_HOST:-cluster1-haproxy.default.svc.cluster.local}
    
    read -p "MySQL Admin Port [3306]: " MYSQL_PORT
    MYSQL_PORT=${MYSQL_PORT:-3306}
    
    read -p "MySQL Admin User [root]: " MYSQL_USER
    MYSQL_USER=${MYSQL_USER:-root}
    
    read -sp "MySQL Admin Password: " MYSQL_PASSWORD
    echo ""
    
    if [ -z "$MYSQL_PASSWORD" ]; then
        echo -e "${RED}Error: Password cannot be empty${NC}"
        exit 1
    fi
    
    # Create or update secret
    if kubectl get secret db-concierge-mysql-admin -n db-concierge &> /dev/null; then
        kubectl delete secret db-concierge-mysql-admin -n db-concierge
    fi
    
    kubectl create secret generic db-concierge-mysql-admin \
        -n db-concierge \
        --from-literal=MYSQL_ADMIN_HOST="${MYSQL_HOST}" \
        --from-literal=MYSQL_ADMIN_PORT="${MYSQL_PORT}" \
        --from-literal=MYSQL_ADMIN_USER="${MYSQL_USER}" \
        --from-literal=MYSQL_ADMIN_PASSWORD="${MYSQL_PASSWORD}"
    
    echo -e "${GREEN}✓ MySQL admin credentials configured${NC}"
fi

# Step 5: Build and deploy operator
echo ""
echo -e "${BLUE}[5/6] Deploying operator...${NC}"

# Check if operator image needs to be built
if [ -f "${SCRIPT_DIR}/operator/Dockerfile" ]; then
    echo -e "${YELLOW}Operator Docker image needs to be built and pushed to a registry.${NC}"
    echo ""
    echo "Options:"
    echo "  1. Build and load into local kind/minikube cluster"
    echo "  2. Build and push to a registry (requires docker login)"
    echo "  3. Skip (use existing image from deployment.yaml)"
    echo ""
    read -p "Choose option [1-3]: " BUILD_OPTION
    
    case $BUILD_OPTION in
        1)
            echo -e "${BLUE}Building image for local cluster...${NC}"
            cd "${SCRIPT_DIR}/operator"
            
            # Detect cluster type
            if kubectl config current-context | grep -q "kind"; then
                docker build -t db-concierge-operator:latest .
                kind load docker-image db-concierge-operator:latest
                echo -e "${GREEN}✓ Image loaded into kind cluster${NC}"
            elif kubectl config current-context | grep -q "minikube"; then
                eval $(minikube docker-env)
                docker build -t db-concierge-operator:latest .
                echo -e "${GREEN}✓ Image built in minikube${NC}"
            else
                echo -e "${YELLOW}Could not detect kind or minikube. Building locally...${NC}"
                docker build -t db-concierge-operator:latest .
                echo -e "${YELLOW}You may need to push this image to your cluster's registry${NC}"
            fi
            cd "${SCRIPT_DIR}"
            ;;
        2)
            read -p "Enter your image registry (e.g., docker.io/myuser): " REGISTRY
            if [ -z "$REGISTRY" ]; then
                echo -e "${RED}Error: Registry cannot be empty${NC}"
                exit 1
            fi
            
            IMAGE="${REGISTRY}/db-concierge-operator:latest"
            echo -e "${BLUE}Building and pushing to ${IMAGE}...${NC}"
            
            cd "${SCRIPT_DIR}/operator"
            docker build -t "${IMAGE}" .
            docker push "${IMAGE}"
            cd "${SCRIPT_DIR}"
            
            # Update deployment.yaml with the new image
            sed -i.bak "s|image: db-concierge-operator:latest|image: ${IMAGE}|g" "${SCRIPT_DIR}/deploy/deployment.yaml"
            echo -e "${GREEN}✓ Image built and pushed${NC}"
            echo -e "${GREEN}✓ deployment.yaml updated with image: ${IMAGE}${NC}"
            ;;
        3)
            echo -e "${YELLOW}Skipping image build. Using image from deployment.yaml${NC}"
            echo -e "${YELLOW}Make sure the image is accessible to your cluster!${NC}"
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            exit 1
            ;;
    esac
fi

# Deploy operator
kubectl apply -f "${SCRIPT_DIR}/deploy/deployment.yaml"
echo -e "${GREEN}✓ Operator deployed${NC}"

# Step 6: Optional - Install developer RBAC
echo ""
echo -e "${BLUE}[6/6] Developer RBAC (optional)...${NC}"
echo -e "${YELLOW}The deploy/dev-rbac.yaml file contains RBAC to allow developers to create AppDatabase resources.${NC}"
echo -e "${YELLOW}You should edit this file to specify which users/groups should have access.${NC}"
echo ""
read -p "Install developer RBAC now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Opening deploy/dev-rbac.yaml for editing...${NC}"
    ${EDITOR:-vi} "${SCRIPT_DIR}/deploy/dev-rbac.yaml"
    
    read -p "Apply the RBAC configuration? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl apply -f "${SCRIPT_DIR}/deploy/dev-rbac.yaml"
        echo -e "${GREEN}✓ Developer RBAC installed${NC}"
    else
        echo -e "${YELLOW}Skipped developer RBAC installation${NC}"
        echo -e "${YELLOW}You can apply it later with: kubectl apply -f deploy/dev-rbac.yaml${NC}"
    fi
else
    echo -e "${YELLOW}Skipped developer RBAC installation${NC}"
    echo -e "${YELLOW}You can apply it later with: kubectl apply -f deploy/dev-rbac.yaml${NC}"
fi

# Wait for operator to be ready
echo ""
echo -e "${BLUE}Waiting for operator to be ready...${NC}"
kubectl wait --for=condition=available --timeout=120s deployment/db-concierge-operator -n db-concierge

# Installation complete
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Installation Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo ""
echo "1. Install the CLI tool:"
echo "   cd cli"
echo "   pip install -r requirements.txt"
echo "   chmod +x bootstrap-mysql-schema"
echo "   sudo cp bootstrap-mysql-schema /usr/local/bin/"
echo ""
echo "2. Test the operator:"
echo "   kubectl get appdatabase -n db-concierge"
echo "   kubectl logs -n db-concierge -l app.kubernetes.io/name=db-concierge-operator"
echo ""
echo "3. Create your first database:"
echo "   bootstrap-mysql-schema --name testdb --namespace default"
echo "   # OR"
echo "   kubectl apply -f examples/wookie-appdatabase.yaml"
echo ""
echo "4. View the examples:"
echo "   ls examples/"
echo ""
echo -e "${YELLOW}Documentation:${NC} See README.md for full usage guide"
echo ""


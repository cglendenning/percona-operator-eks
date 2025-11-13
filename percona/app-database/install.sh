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

# Check if Docker is available (needed for building)
DOCKER_AVAILABLE=false
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        DOCKER_AVAILABLE=true
    fi
fi

# Check if operator image needs to be built
if [ -f "${SCRIPT_DIR}/operator/Dockerfile" ]; then
    echo -e "${YELLOW}The DB Concierge operator needs a container image.${NC}"
    echo ""
    echo -e "${YELLOW}Why?${NC} Unlike Percona's pre-built images, this is a custom operator built from source."
    echo ""
    
    if [ "$DOCKER_AVAILABLE" = false ]; then
        echo -e "${RED}⚠ Docker is not available on this machine${NC}"
        echo ""
        echo "You have several options:"
        echo ""
        echo "  A. Install Docker on this machine and run ./install.sh again"
        echo "  B. Build the image on another machine with Docker, then skip this step"
        echo "  C. Use AWS CodeBuild to build and push the image (I can generate the buildspec)"
        echo ""
        read -p "Choose option [A/B/C]: " DOCKER_OPTION
        
        case $DOCKER_OPTION in
            A|a)
                echo ""
                echo -e "${BLUE}Install Docker:${NC}"
                echo ""
                echo "For Amazon Linux 2:"
                echo "  sudo yum update -y"
                echo "  sudo yum install docker -y"
                echo "  sudo service docker start"
                echo "  sudo usermod -a -G docker \$USER"
                echo "  # Log out and back in for group changes to take effect"
                echo ""
                echo "For Ubuntu/Debian:"
                echo "  curl -fsSL https://get.docker.com -o get-docker.sh"
                echo "  sudo sh get-docker.sh"
                echo "  sudo usermod -aG docker \$USER"
                echo "  # Log out and back in"
                echo ""
                echo "For macOS:"
                echo "  Install Docker Desktop from https://www.docker.com/products/docker-desktop"
                echo ""
                echo "After installing Docker, run ./install.sh again"
                exit 0
                ;;
            B|b)
                echo ""
                echo -e "${BLUE}Build on another machine:${NC}"
                echo ""
                echo "1. On a machine with Docker, run these commands:"
                echo ""
                
                # Get AWS info
                AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
                AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
                
                if [ -n "$AWS_ACCOUNT_ID" ]; then
                    echo "   cd ${SCRIPT_DIR}/operator"
                    echo "   aws ecr get-login-password --region ${AWS_REGION} | \\"
                    echo "     docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                    echo "   docker build -t ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/db-concierge-operator:latest ."
                    echo "   docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/db-concierge-operator:latest"
                    echo ""
                    echo "2. Update deployment.yaml on this machine:"
                    echo "   sed -i 's|image: db-concierge-operator:latest|image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/db-concierge-operator:latest|g' ${SCRIPT_DIR}/deploy/deployment.yaml"
                else
                    echo "   See the manual instructions in README.md"
                fi
                echo ""
                echo "3. Then come back here and choose option 3 (Skip) when you re-run ./install.sh"
                echo ""
                exit 0
                ;;
            C|c)
                echo ""
                echo -e "${BLUE}Generating AWS CodeBuild buildspec...${NC}"
                
                # Create buildspec.yml
                cat > "${SCRIPT_DIR}/buildspec.yml" <<'BUILDSPEC_EOF'
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
      - REPOSITORY_URI=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/db-concierge-operator
      - IMAGE_TAG=${CODEBUILD_RESOLVED_SOURCE_VERSION:-latest}
  build:
    commands:
      - echo Build started on `date`
      - echo Building the Docker image...
      - cd operator
      - docker build -t $REPOSITORY_URI:latest .
      - docker tag $REPOSITORY_URI:latest $REPOSITORY_URI:$IMAGE_TAG
  post_build:
    commands:
      - echo Build completed on `date`
      - echo Pushing the Docker image...
      - docker push $REPOSITORY_URI:latest
      - docker push $REPOSITORY_URI:$IMAGE_TAG
      - echo Writing image URI to file...
      - echo $REPOSITORY_URI:latest > image_uri.txt
artifacts:
  files:
    - image_uri.txt
BUILDSPEC_EOF
                
                echo -e "${GREEN}✓ Created buildspec.yml${NC}"
                echo ""
                echo "To build with CodeBuild:"
                echo ""
                echo "1. Create a CodeBuild project:"
                echo "   - Go to AWS CodeBuild console"
                echo "   - Create a new project"
                echo "   - Source: Your git repository (or upload this directory as a zip)"
                echo "   - Environment: Managed image, Amazon Linux 2, Standard runtime, 'aws/codebuild/standard:5.0'"
                echo "   - Buildspec: Use the buildspec.yml file"
                echo "   - Service role: Create new or use existing with ECR permissions"
                echo ""
                echo "2. Or use AWS CLI:"
                AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
                cat > "${SCRIPT_DIR}/create-codebuild-project.sh" <<SCRIPT_EOF
#!/bin/bash
aws codebuild create-project \\
  --name db-concierge-builder \\
  --source type=NO_SOURCE \\
  --artifacts type=NO_ARTIFACTS \\
  --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:5.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \\
  --service-role <YOUR_CODEBUILD_ROLE_ARN> \\
  --region ${AWS_REGION}

# Then trigger a build:
# aws codebuild start-build --project-name db-concierge-builder --region ${AWS_REGION}
SCRIPT_EOF
                chmod +x "${SCRIPT_DIR}/create-codebuild-project.sh"
                echo "   See: create-codebuild-project.sh (edit with your role ARN)"
                echo ""
                echo "3. After the build completes, update deployment.yaml and continue installation"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                exit 1
                ;;
        esac
    fi
    
    # Detect cluster type
    CLUSTER_CONTEXT=$(kubectl config current-context)
    
    if echo "$CLUSTER_CONTEXT" | grep -q "kind"; then
        echo -e "${GREEN}Detected kind cluster - can build and load locally${NC}"
        DETECTED_TYPE="kind"
    elif echo "$CLUSTER_CONTEXT" | grep -q "minikube"; then
        echo -e "${GREEN}Detected minikube cluster - can build locally${NC}"
        DETECTED_TYPE="minikube"
    elif echo "$CLUSTER_CONTEXT" | grep -q "eks" || kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' | grep -q "aws"; then
        echo -e "${GREEN}Detected EKS cluster - need to use container registry${NC}"
        DETECTED_TYPE="eks"
    elif echo "$CLUSTER_CONTEXT" | grep -q "gke" || kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' | grep -q "gce"; then
        echo -e "${GREEN}Detected GKE cluster - need to use container registry${NC}"
        DETECTED_TYPE="gke"
    else
        echo -e "${YELLOW}Could not detect cluster type${NC}"
        DETECTED_TYPE="unknown"
    fi
    
    echo ""
    echo "Options:"
    echo ""
    
    if [ "$DETECTED_TYPE" = "eks" ]; then
        echo "  1. AWS ECR (Elastic Container Registry) - RECOMMENDED for EKS"
        echo "     Creates/uses an ECR repository in your AWS account"
        echo ""
        echo "  2. Docker Hub or other public registry"
        echo "     Requires: docker login <registry>"
        echo ""
        echo "  3. Skip (I've already built and pushed the image)"
        echo ""
    elif [ "$DETECTED_TYPE" = "gke" ]; then
        echo "  1. GCR (Google Container Registry) - RECOMMENDED for GKE"
        echo "     Uses gcr.io/<your-project>/db-concierge-operator"
        echo ""
        echo "  2. Docker Hub or other public registry"
        echo "     Requires: docker login <registry>"
        echo ""
        echo "  3. Skip (I've already built and pushed the image)"
        echo ""
    elif [ "$DETECTED_TYPE" = "kind" ] || [ "$DETECTED_TYPE" = "minikube" ]; then
        echo "  1. Build and load into local cluster (no registry needed)"
        echo ""
        echo "  2. Build and push to registry anyway"
        echo ""
        echo "  3. Skip (use existing image)"
        echo ""
    else
        echo "  1. Build and push to Docker Hub or custom registry"
        echo ""
        echo "  2. Skip (I've already built and pushed the image)"
        echo ""
    fi
    
    read -p "Choose option: " BUILD_OPTION
    
    case $BUILD_OPTION in
        1)
            if [ "$DETECTED_TYPE" = "kind" ] || [ "$DETECTED_TYPE" = "minikube" ]; then
                # Local cluster - build and load
                echo -e "${BLUE}Building image for local cluster...${NC}"
                cd "${SCRIPT_DIR}/operator"
                
                if [ "$DETECTED_TYPE" = "kind" ]; then
                    docker build -t db-concierge-operator:latest .
                    kind load docker-image db-concierge-operator:latest
                    echo -e "${GREEN}✓ Image loaded into kind cluster${NC}"
                else
                    eval $(minikube docker-env)
                    docker build -t db-concierge-operator:latest .
                    echo -e "${GREEN}✓ Image built in minikube${NC}"
                fi
                cd "${SCRIPT_DIR}"
                
            elif [ "$DETECTED_TYPE" = "eks" ]; then
                # AWS ECR
                echo -e "${BLUE}Setting up AWS ECR...${NC}"
                
                # Get AWS account ID and region
                AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
                AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
                
                if [ -z "$AWS_ACCOUNT_ID" ]; then
                    echo -e "${RED}Error: Could not get AWS account ID. Is AWS CLI configured?${NC}"
                    echo "Run: aws configure"
                    exit 1
                fi
                
                read -p "AWS Region [${AWS_REGION}]: " INPUT_REGION
                AWS_REGION=${INPUT_REGION:-$AWS_REGION}
                
                ECR_REPO="db-concierge-operator"
                ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
                
                echo -e "${BLUE}Creating ECR repository if it doesn't exist...${NC}"
                aws ecr describe-repositories --repository-names ${ECR_REPO} --region ${AWS_REGION} 2>/dev/null || \
                    aws ecr create-repository --repository-name ${ECR_REPO} --region ${AWS_REGION}
                
                echo -e "${BLUE}Logging into ECR...${NC}"
                aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
                
                echo -e "${BLUE}Building and pushing image...${NC}"
                cd "${SCRIPT_DIR}/operator"
                docker build -t ${ECR_URI}:latest .
                docker push ${ECR_URI}:latest
                cd "${SCRIPT_DIR}"
                
                # Update deployment.yaml
                sed -i.bak "s|image: db-concierge-operator:latest|image: ${ECR_URI}:latest|g" "${SCRIPT_DIR}/deploy/deployment.yaml"
                
                echo -e "${GREEN}✓ Image pushed to ECR: ${ECR_URI}:latest${NC}"
                echo -e "${GREEN}✓ deployment.yaml updated${NC}"
                
            elif [ "$DETECTED_TYPE" = "gke" ]; then
                # Google Container Registry
                echo -e "${BLUE}Setting up GCR...${NC}"
                
                GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
                if [ -z "$GCP_PROJECT" ]; then
                    echo -e "${RED}Error: No GCP project configured. Run: gcloud config set project <project-id>${NC}"
                    exit 1
                fi
                
                read -p "GCP Project [${GCP_PROJECT}]: " INPUT_PROJECT
                GCP_PROJECT=${INPUT_PROJECT:-$GCP_PROJECT}
                
                GCR_URI="gcr.io/${GCP_PROJECT}/db-concierge-operator"
                
                echo -e "${BLUE}Configuring Docker for GCR...${NC}"
                gcloud auth configure-docker
                
                echo -e "${BLUE}Building and pushing image...${NC}"
                cd "${SCRIPT_DIR}/operator"
                docker build -t ${GCR_URI}:latest .
                docker push ${GCR_URI}:latest
                cd "${SCRIPT_DIR}"
                
                # Update deployment.yaml
                sed -i.bak "s|image: db-concierge-operator:latest|image: ${GCR_URI}:latest|g" "${SCRIPT_DIR}/deploy/deployment.yaml"
                
                echo -e "${GREEN}✓ Image pushed to GCR: ${GCR_URI}:latest${NC}"
                echo -e "${GREEN}✓ deployment.yaml updated${NC}"
            fi
            ;;
        2)
            if [ "$DETECTED_TYPE" = "kind" ] || [ "$DETECTED_TYPE" = "minikube" ]; then
                # User wants to push to registry from local cluster
                read -p "Enter your image registry (e.g., docker.io/myuser or myregistry.example.com): " REGISTRY
            else
                # Regular registry push
                read -p "Enter your image registry (e.g., docker.io/myuser): " REGISTRY
            fi
            
            if [ -z "$REGISTRY" ]; then
                echo -e "${RED}Error: Registry cannot be empty${NC}"
                exit 1
            fi
            
            IMAGE="${REGISTRY}/db-concierge-operator:latest"
            echo -e "${BLUE}Building and pushing to ${IMAGE}...${NC}"
            echo -e "${YELLOW}Note: Make sure you're logged in (docker login <registry>)${NC}"
            
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
            echo -e "${YELLOW}Skipping image build.${NC}"
            echo -e "${YELLOW}Make sure deploy/deployment.yaml has the correct image reference!${NC}"
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


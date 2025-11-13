# DB Concierge - MySQL Database Provisioning for Applications

A Kubernetes-native solution for self-service MySQL database provisioning. Provides clean separation between infrastructure (Percona XtraDB Cluster operations) and application concerns (database schemas and users).

## Quick Overview

**The Problem**: Hard-coding `CREATE DATABASE` statements in PXC cluster configuration mixes application concerns with infrastructure, creating operational headaches and breaking separation of concerns.

**The Solution**: DB Concierge is a Kubernetes operator that lets developers request databases through a simple CRD or CLI command. The operator handles database creation, user provisioning, and credential management - all without giving developers admin access.

```bash
# Developers run this:
bootstrap-mysql-schema --name myapp --namespace myapp

# Gets:
# ✓ MySQL database "myapp" 
# ✓ MySQL user "myapp_app" (scoped to myapp.* only)
# ✓ Kubernetes Secret with credentials in myapp namespace
```

---

## 📖 Table of Contents

### For Platform Teams (Setup & Installation)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Granting Developer Access](#granting-developer-access)
- [Monitoring & Operations](#monitoring--operations)
- [Uninstallation](#uninstallation)

### For Developers (Usage)
- [Creating a Database](#creating-a-database)
  - [Using the CLI](#using-the-cli)
  - [Using Kubernetes YAML](#using-kubernetes-yaml)
- [Using Credentials in Your Application](#using-credentials-in-your-application)
- [Local Development](#local-development)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

### Reference
- [Architecture](#architecture)
- [Security Model](#security-model)
- [AppDatabase Spec Reference](#appdatabase-spec-reference)
- [Deletion Policies](#deletion-policies)

---

# For Platform Teams

> **Note for Developers**: If you're just using the system to create databases, skip to the [For Developers](#for-developers) section below.

## Prerequisites

- Kubernetes cluster with Percona XtraDB Cluster (PXC) installed and running
- `kubectl` configured with cluster admin access
- MySQL root/admin credentials for your PXC cluster
- **Docker** (for building the operator image) - OR see [alternatives](#building-without-docker) below
- **For EKS**: AWS CLI configured (`aws configure`) - will use AWS ECR
- **For GKE**: gcloud CLI configured - will use Google Container Registry
- **For local clusters** (kind/minikube): No registry needed

## Installation

### Quick Install

```bash
cd percona/app-database
./install.sh
```

The interactive installer will:
1. Install the `AppDatabase` CRD
2. Create the `db-concierge` namespace
3. Set up RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
4. Prompt for your PXC admin credentials
5. **Build and push operator image** (see note below)
6. Deploy the operator
7. Optionally configure developer RBAC

#### About the Operator Image

**Why do I need to build an image?** Unlike Percona's operators which use pre-built public images (e.g., `percona/percona-xtradb-cluster-operator`), DB Concierge is a custom operator built from source.

**Where does it go?** The installer detects your cluster type:

- **EKS**: Automatically uses AWS ECR (Elastic Container Registry)
  - Creates an ECR repository: `<account-id>.dkr.ecr.<region>.amazonaws.com/db-concierge-operator`
  - Requires: AWS CLI configured (`aws configure`)
  - No separate registry setup needed!

- **GKE**: Automatically uses Google Container Registry
  - Uses: `gcr.io/<project>/db-concierge-operator`
  - Requires: gcloud CLI configured

- **Local (kind/minikube)**: Loads directly into cluster
  - No registry needed at all

- **Other clusters**: You can use Docker Hub or any registry you have access to

**During installation**, you'll be prompted for:

1. **MySQL admin credentials:**
   ```
   MySQL Admin Host: cluster1-haproxy.default.svc.cluster.local
   MySQL Admin Port: 3306
   MySQL Admin User: root
   MySQL Admin Password: <your-pxc-root-password>
   ```

2. **Image registry choice** (for EKS, option 1 is recommended):
   ```
   Options:
     1. AWS ECR (Elastic Container Registry) - RECOMMENDED for EKS
        Creates/uses an ECR repository in your AWS account
     
     2. Docker Hub or other public registry
        Requires: docker login <registry>
     
     3. Skip (I've already built and pushed the image)
   ```

### Manual Installation

If you prefer manual installation:

```bash
# 1. Install CRD
kubectl apply -f crds/appdatabase-crd.yaml

# 2. Create namespace and RBAC
kubectl apply -f deploy/namespace.yaml
kubectl apply -f deploy/serviceaccount.yaml
kubectl apply -f deploy/clusterrole.yaml
kubectl apply -f deploy/clusterrolebinding.yaml

# 3. Create MySQL admin credentials secret
kubectl create secret generic db-concierge-mysql-admin \
  -n db-concierge \
  --from-literal=MYSQL_ADMIN_HOST=cluster1-haproxy.default.svc.cluster.local \
  --from-literal=MYSQL_ADMIN_PORT=3306 \
  --from-literal=MYSQL_ADMIN_USER=root \
  --from-literal=MYSQL_ADMIN_PASSWORD=your-root-password

# 4. Build and push operator image
cd operator

# For EKS with ECR:
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)
ECR_REPO=db-concierge-operator

# Create ECR repository
aws ecr create-repository --repository-name ${ECR_REPO} --region ${AWS_REGION}

# Login to ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build and push
docker build -t ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest .
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest

# Update deployment with ECR image
sed -i "s|image: db-concierge-operator:latest|image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest|g" ../deploy/deployment.yaml

# 5. Deploy operator
kubectl apply -f ../deploy/deployment.yaml
```

### Verify Installation

```bash
# Check operator is running
kubectl get pods -n db-concierge

# Should show:
# NAME                                    READY   STATUS    RESTARTS   AGE
# db-concierge-operator-xxxxxxxxxx-xxxxx  1/1     Running   0          1m

# Check CRD is installed
kubectl get crd appdatabases.db.stillwaters.io
```

### Building Without Docker

If you're running the installer on a machine without Docker (e.g., a bastion host), you have several options:

#### Option 1: Install Docker

**Amazon Linux 2:**
```bash
sudo yum update -y
sudo yum install docker -y
sudo service docker start
sudo usermod -a -G docker $USER
# Log out and back in for group changes to take effect
```

**Ubuntu/Debian:**
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
# Log out and back in
```

**macOS:**
Install Docker Desktop from https://www.docker.com/products/docker-desktop

#### Option 2: Build on Another Machine

Build the image on your laptop or a build server, then push to ECR:

```bash
# On machine with Docker:
cd percona/app-database/operator

# Login to ECR
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build and push
docker build -t ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/db-concierge-operator:latest .
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/db-concierge-operator:latest

# Back on the machine running kubectl, update deployment:
cd percona/app-database
sed -i "s|image: db-concierge-operator:latest|image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/db-concierge-operator:latest|g" deploy/deployment.yaml

# Then continue with installation
kubectl apply -f deploy/deployment.yaml
```

#### Option 3: Use AWS CodeBuild

Create a CodeBuild project to build and push the image:

1. **Create `buildspec.yml`** (the installer can generate this for you):

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
      - REPOSITORY_URI=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/db-concierge-operator
  build:
    commands:
      - echo Building the Docker image...
      - cd operator
      - docker build -t $REPOSITORY_URI:latest .
  post_build:
    commands:
      - echo Pushing the Docker image...
      - docker push $REPOSITORY_URI:latest
```

2. **Create CodeBuild project** with this buildspec and appropriate IAM role with ECR permissions

3. **Trigger build** and wait for completion

4. **Update deployment.yaml** with the ECR URI and continue installation

### Troubleshooting Installation

#### EKS: ImagePullBackOff Error

If the operator pod shows `ImagePullBackOff`:

```bash
kubectl describe pod -n db-concierge -l app.kubernetes.io/name=db-concierge-operator
```

**Common causes:**

1. **ECR repository doesn't exist**: Create it manually:
   ```bash
   aws ecr create-repository --repository-name db-concierge-operator --region <your-region>
   ```

2. **EKS nodes can't pull from ECR**: Verify your node IAM role has ECR permissions:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "ecr:GetAuthorizationToken",
           "ecr:BatchCheckLayerAvailability",
           "ecr:GetDownloadUrlForLayer",
           "ecr:BatchGetImage"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

3. **Image wasn't pushed**: Verify image exists in ECR:
   ```bash
   aws ecr describe-images --repository-name db-concierge-operator --region <your-region>
   ```

4. **Wrong image reference in deployment.yaml**: Check the image path:
   ```bash
   kubectl get deployment db-concierge-operator -n db-concierge -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

## Configuration

### Updating MySQL Admin Credentials

If your PXC admin password changes:

```bash
kubectl edit secret db-concierge-mysql-admin -n db-concierge
# Update MYSQL_ADMIN_PASSWORD

# Restart operator to pick up changes
kubectl rollout restart deployment/db-concierge-operator -n db-concierge
```

### Configuring for Multiple PXC Clusters

If you have multiple PXC clusters (dev, staging, prod), developers specify which cluster in the `clusterRef` field:

```yaml
spec:
  clusterRef: prod-pxc-haproxy  # Points to production cluster
```

You may want to deploy multiple operator instances with different credentials, or configure one operator to handle multiple clusters.

## Granting Developer Access

Allow developers to create `AppDatabase` resources:

1. Edit `deploy/dev-rbac.yaml` to specify which users/groups should have access
2. Apply it:

```bash
kubectl apply -f deploy/dev-rbac.yaml
```

Example configuration in `dev-rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developers-can-create-databases
  namespace: default  # Change to your dev namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: appdatabase-creator
subjects:
  - kind: User
    name: developer@example.com
  - kind: Group
    name: developers
```

Create a `RoleBinding` per namespace where developers should be able to request databases.

## Monitoring & Operations

### View All Managed Databases

```bash
kubectl get appdatabase -n db-concierge

# Example output:
# NAME     DATABASE   NAMESPACE   PHASE   AGE
# myapp    myapp      myapp       Ready   5m
# wookie   wookie     wookie      Ready   10m
```

### Check Operator Logs

```bash
kubectl logs -n db-concierge -l app.kubernetes.io/name=db-concierge-operator -f
```

### Check Specific Database Status

```bash
kubectl describe appdatabase myapp -n db-concierge
```

### Common Operational Tasks

**List all secrets created by the operator:**
```bash
kubectl get secrets -A -l app.kubernetes.io/managed-by=db-concierge-operator
```

**Force reconciliation of a database:**
```bash
kubectl annotate appdatabase myapp -n db-concierge reconcile=$(date +%s) --overwrite
```

**View operator metrics** (if exposed):
```bash
kubectl port-forward -n db-concierge svc/db-concierge-operator 8080:8080
curl http://localhost:8080/healthz
```

## Uninstallation

```bash
./uninstall.sh
```

The uninstall script will:
- Remove the operator deployment
- Remove RBAC resources
- Optionally remove secrets and namespace
- Optionally remove the CRD (⚠️ this deletes all AppDatabase resources)

**Note**: Uninstalling does NOT delete the actual MySQL databases, users, or application secrets. You must clean these up manually if needed.

---

# For Developers

> **Start here** if you're a developer who wants to create a database for your application.

## Creating a Database

You have two options: use the CLI tool (easiest) or create a Kubernetes YAML file (GitOps-friendly).

### Using the CLI

#### Install the CLI Tool

```bash
cd cli
pip install -r requirements.txt
chmod +x bootstrap-mysql-schema
sudo cp bootstrap-mysql-schema /usr/local/bin/
```

Or use it directly without installing:
```bash
cd cli
./bootstrap-mysql-schema --help
```

#### Create Your First Database

```bash
bootstrap-mysql-schema --name myapp --namespace myapp
```

This creates:
- MySQL database named `myapp`
- MySQL user `myapp_app` with access only to the `myapp` database
- Kubernetes Secret `myapp-mysql-creds` in the `myapp` namespace

**Output:**
```
DB Concierge - Bootstrap MySQL Schema
Creating database: myapp
Target namespace: myapp
PXC cluster:      cluster1-haproxy

appdatabase.db.stillwaters.io/myapp created

Waiting for database provisioning...
✓ Database provisioned successfully!

Database Created Successfully!

Database Information:
  Database Name: myapp
  Username:      myapp_app
  Host:          cluster1-haproxy.default.svc.cluster.local
  Port:          3306

Kubernetes Secret:
  Name:      myapp-mysql-creds
  Namespace: myapp

Connect to MySQL:
  mysql -h cluster1-haproxy.default.svc.cluster.local \
        -P 3306 \
        -u myapp_app \
        -p************ \
        myapp
```

#### CLI Options

```bash
# Specify custom PXC cluster
bootstrap-mysql-schema --name myapp --namespace myapp --cluster my-pxc-haproxy

# Output credentials as environment variables (for local dev)
bootstrap-mysql-schema --name myapp --namespace myapp --output-env

# Set deletion policy to Delete (⚠️ database will be dropped when AppDatabase is deleted)
bootstrap-mysql-schema --name myapp --namespace myapp --deletion-policy Delete

# Don't wait for provisioning (async)
bootstrap-mysql-schema --name myapp --namespace myapp --no-wait
```

### Using Kubernetes YAML

Create `database.yaml`:

```yaml
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: myapp
  namespace: db-concierge
spec:
  clusterRef: cluster1-haproxy
  dbName: myapp
  appNamespace: myapp
  deletionPolicy: Retain
```

Apply it:

```bash
kubectl apply -f database.yaml

# Watch status
kubectl get appdatabase myapp -n db-concierge -w
```

Once the status shows `Ready`, your database and secret are created.

## Using Credentials in Your Application

The operator creates a Kubernetes Secret in your application's namespace with these keys:

- `host` - MySQL host (e.g., `cluster1-haproxy.default.svc.cluster.local`)
- `port` - MySQL port (usually `3306`)
- `username` - MySQL username (e.g., `myapp_app`)
- `password` - Generated secure password
- `database` - Database name
- `connection-string` - Full MySQL connection URL

### In a Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  template:
    spec:
      containers:
        - name: app
          image: myapp:latest
          env:
            # Individual environment variables
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: myapp-mysql-creds
                  key: host
            - name: DB_PORT
              valueFrom:
                secretKeyRef:
                  name: myapp-mysql-creds
                  key: port
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: myapp-mysql-creds
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: myapp-mysql-creds
                  key: password
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: myapp-mysql-creds
                  key: database
            
            # Or use the full connection string
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: myapp-mysql-creds
                  key: connection-string
```

### View Secret Contents

```bash
# View secret
kubectl get secret myapp-mysql-creds -n myapp -o yaml

# Get specific values
kubectl get secret myapp-mysql-creds -n myapp -o jsonpath='{.data.username}' | base64 -d
kubectl get secret myapp-mysql-creds -n myapp -o jsonpath='{.data.password}' | base64 -d
```

## Local Development

### Connect from Your Laptop

```bash
# Port forward to PXC cluster
kubectl port-forward svc/cluster1-haproxy 3306:3306 &

# Get credentials
USERNAME=$(kubectl get secret myapp-mysql-creds -n myapp -o jsonpath='{.data.username}' | base64 -d)
PASSWORD=$(kubectl get secret myapp-mysql-creds -n myapp -o jsonpath='{.data.password}' | base64 -d)

# Connect with mysql client
mysql -h 127.0.0.1 -P 3306 -u "$USERNAME" -p"$PASSWORD" myapp

# Create your tables
CREATE TABLE users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  username VARCHAR(50) NOT NULL,
  email VARCHAR(100) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Export as Environment Variables

```bash
bootstrap-mysql-schema --name myapp --namespace myapp --output-env > .env
source .env

# Now you have:
# MYSQL_HOST
# MYSQL_PORT
# MYSQL_USER
# MYSQL_PASSWORD
# MYSQL_DATABASE
# MYSQL_URL
```

## Examples

### Example 1: Simple Application

```bash
# Create database
bootstrap-mysql-schema --name frontend --namespace frontend

# Deploy app
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: frontend:latest
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: frontend-mysql-creds
                  key: connection-string
EOF
```

### Example 2: Multiple Databases for Microservices

```yaml
# databases.yaml
---
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: user-service
  namespace: db-concierge
spec:
  clusterRef: cluster1-haproxy
  dbName: users
  appNamespace: user-service
---
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: order-service
  namespace: db-concierge
spec:
  clusterRef: cluster1-haproxy
  dbName: orders
  appNamespace: order-service
---
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: inventory-service
  namespace: db-concierge
spec:
  clusterRef: cluster1-haproxy
  dbName: inventory
  appNamespace: inventory-service
```

Apply: `kubectl apply -f databases.yaml`

### Example 3: GitOps with Helm

In your Helm chart's `values.yaml`:

```yaml
database:
  create: true
  name: ""  # Defaults to release name
  clusterRef: cluster1-haproxy
  deletionPolicy: Retain
```

In `templates/appdatabase.yaml`:

```yaml
{{- if .Values.database.create }}
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: {{ .Values.database.name | default .Release.Name }}
  namespace: db-concierge
spec:
  clusterRef: {{ .Values.database.clusterRef }}
  dbName: {{ .Values.database.name | default .Release.Name }}
  appNamespace: {{ .Release.Namespace }}
  deletionPolicy: {{ .Values.database.deletionPolicy }}
{{- end }}
```

More examples in the `examples/` directory.

## Troubleshooting

### "Database provisioning failed"

Check operator logs:
```bash
kubectl logs -n db-concierge -l app.kubernetes.io/name=db-concierge-operator --tail=50
```

Common causes:
- Wrong MySQL admin credentials → Update secret and restart operator
- PXC cluster not reachable → Check network policies and service names
- MySQL connection refused → Verify PXC cluster is running

### "Secret not found in namespace"

The database may still be provisioning. Check status:
```bash
kubectl get appdatabase myapp -n db-concierge
# Look for Phase: Ready
```

If status is `Ready` but secret is missing, check operator logs for errors.

### "Cannot connect to database from application"

1. **Verify PXC is running:**
   ```bash
   kubectl get pods -l app.kubernetes.io/name=percona-xtradb-cluster
   ```

2. **Check service exists:**
   ```bash
   kubectl get svc cluster1-haproxy
   ```

3. **Test DNS resolution from app pod:**
   ```bash
   kubectl exec -it <your-app-pod> -n myapp -- nslookup cluster1-haproxy.default.svc.cluster.local
   ```

4. **Check network policies** - ensure traffic is allowed from your app namespace to PXC namespace

5. **Verify credentials:**
   ```bash
   kubectl get secret myapp-mysql-creds -n myapp -o yaml
   ```

### "Permission denied creating AppDatabase"

You need RBAC permissions. Ask your platform team to grant you access via `dev-rbac.yaml`.

### Database Already Exists

The operator is idempotent. If the database exists:
- Database creation is skipped (no-op)
- User password is updated
- Secret is created/updated with current credentials

This is safe and expected behavior.

---

# Reference

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Developer Interface                       │
│  • CLI: bootstrap-mysql-schema                               │
│  • YAML: AppDatabase custom resources                        │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                 Kubernetes Control Plane                     │
│  • AppDatabase CRD                                           │
│  • RBAC (ClusterRoles, RoleBindings)                         │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              DB Concierge Operator (Kopf)                    │
│  Watches AppDatabase resources and reconciles:               │
│  1. CREATE DATABASE IF NOT EXISTS                            │
│  2. CREATE USER / ALTER USER                                 │
│  3. GRANT ALL PRIVILEGES ON dbname.*                         │
│  4. Create/update Kubernetes Secret                          │
└────┬───────────────────────────────┬────────────────────────┘
     │                               │
     ▼                               ▼
┌─────────────────┐    ┌──────────────────────────────────────┐
│ Percona XtraDB  │    │    Application Namespace             │
│ Cluster         │    │  • Secret with credentials           │
│  • Databases    │    │  • Application pods mount secret     │
│  • Users        │    │  • Connect to MySQL                  │
└─────────────────┘    └──────────────────────────────────────┘
```

### Data Flow

1. Developer creates `AppDatabase` resource (via CLI or YAML)
2. Operator receives watch event
3. Operator connects to MySQL using admin credentials
4. Operator executes: CREATE DATABASE, CREATE USER, GRANT
5. Operator creates Kubernetes Secret in application namespace
6. Operator updates AppDatabase status to `Ready`
7. Application mounts secret and connects to database

### Separation of Concerns

| Layer | Owns | Managed By |
|-------|------|------------|
| **Infrastructure** | PXC cluster topology, HA, backups, resources, versions | Percona Operator + Platform Team |
| **Concierge** | Database creation, user provisioning, secret management | DB Concierge Operator |
| **Application** | Tables, indexes, migrations, queries, business logic | Application Code |

## Security Model

### What Developers Get

✅ Ability to create `AppDatabase` resources in their namespaces  
✅ Read access to secrets in their namespaces  
✅ MySQL user with access **only** to their database  

### What Developers Don't Get

❌ MySQL root/admin credentials  
❌ Access to other applications' databases  
❌ Access to other namespaces' secrets  
❌ Ability to grant additional MySQL privileges  

### Operator Security

- Runs with minimal Kubernetes RBAC (only what's needed)
- MySQL admin credentials stored in Kubernetes Secret (encrypted at rest if etcd encryption enabled)
- Non-root container (UID 1000)
- Security context with dropped capabilities
- Passwords never logged

### MySQL Permission Scoping

Each application user is granted:
```sql
GRANT ALL PRIVILEGES ON `dbname`.* TO 'username'@'%';
```

This allows full access to their database but **nothing else**. Users cannot:
- Access other databases
- View `mysql.user` table
- Grant privileges to other users
- Create databases

## AppDatabase Spec Reference

```yaml
apiVersion: db.stillwaters.io/v1
kind: AppDatabase
metadata:
  name: myapp              # Resource name in Kubernetes
  namespace: db-concierge  # Always db-concierge
spec:
  # Required fields
  clusterRef: string       # PXC service name (e.g., cluster1-haproxy)
  dbName: string           # MySQL database name (alphanumeric + underscore)
  appNamespace: string     # Target namespace for secret
  
  # Optional fields
  secretName: string       # Custom secret name (default: {dbName}-mysql-creds)
  userName: string         # Custom MySQL username (default: {dbName}_app)
  charset: string          # Character set (default: utf8mb4)
  collation: string        # Collation (default: utf8mb4_unicode_ci)
  deletionPolicy: string   # Retain or Delete (default: Retain)

status:
  phase: string            # Pending, Creating, Ready, or Failed
  message: string          # Human-readable status
  userName: string         # Actual MySQL username created
  secretName: string       # Actual secret name created
  connectionString: string # Connection string template
  lastReconcileTime: date  # Last reconciliation timestamp
```

### Field Validation

- `dbName`: Must match pattern `^[a-zA-Z0-9_]+$`
- `userName`: Must match pattern `^[a-zA-Z0-9_]+$`
- `deletionPolicy`: Must be either `Retain` or `Delete`

## Deletion Policies

### Retain (Default, Recommended)

When an `AppDatabase` resource is deleted, the MySQL database and user are **kept**.

```yaml
spec:
  deletionPolicy: Retain
```

**Use case**: Production environments, any case where data loss is unacceptable.

**Cleanup**: Manual. To remove database:
```sql
mysql> DROP DATABASE myapp;
mysql> DROP USER 'myapp_app'@'%';
```

### Delete (Dangerous)

When an `AppDatabase` resource is deleted, the MySQL database and user are **dropped**.

```yaml
spec:
  deletionPolicy: Delete
```

⚠️ **WARNING**: This will delete all data in the database!

**Use case**: Development/testing environments only.

**Note**: The Kubernetes Secret is NOT deleted (for audit purposes). Delete it manually if needed:
```bash
kubectl delete secret myapp-mysql-creds -n myapp
```

---

## Additional Resources

- **Examples**: See the `examples/` directory for more complex scenarios
- **CLI Documentation**: See `cli/README.md` for detailed CLI usage
- **Operator Code**: See `operator/` directory for implementation details

## Contributing

Contributions welcome! Areas for improvement:
- PostgreSQL support
- Read-only user creation
- Custom SQL initialization scripts
- Prometheus metrics
- Admission webhooks

## License

[Specify your license]

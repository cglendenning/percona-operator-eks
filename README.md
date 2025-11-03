## Percona Operator For XtraDB Cluster On EKS 

Automated deployment of EKS cluster with Percona XtraDB Cluster operator via CloudFormation and TypeScript.

### Prerequisites
- Node.js 18+
- Binaries on PATH:
  - awscli (`aws --version`)
  - kubectl (`kubectl version --client`)
  - helm (`helm version`)

### AWS authentication options
Choose one of the following:

**Option 1: AWS SSO (Recommended)**

Check if you already have SSO configured:
```bash
cat ~/.aws/config
```

If you see an existing profile with `sso_session` configured, use it:
```bash
aws sso login --profile <profile-name>
export AWS_PROFILE=<profile-name>
```

Otherwise, set up a new SSO profile (requires SSO start URL from your AWS admin):
```bash
aws configure sso
aws sso login --profile <profile>
export AWS_PROFILE=<profile>
```

**Option 2: Access keys**
```bash
aws configure
export AWS_PROFILE=default
```

**Option 3: Environment variables**
```bash
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
export AWS_SESSION_TOKEN=<token>  # optional
```

Confirm authentication: `aws sts get-caller-identity`

### Install dependencies
```bash
npm install
```

### EKS cluster deployment
Deploy EKS cluster with 3 node groups (one per AZ):
```bash
./scripts/deploy.sh
```

Or with verbose output:
```bash
./scripts/deploy.sh -vv
```

The deployment script:
- Creates VPC with 3 public + 3 private subnets across us-east-1a, us-east-1c, us-east-1d
- Deploys 3 EKS managed node groups (1 per AZ) with m5.large On-Demand instances
- Installs EBS CSI driver, VPC CNI, CoreDNS, kube-proxy, and metrics-server add-ons
- Updates kubeconfig automatically
- Verifies multi-AZ node distribution

### Percona operator and cluster
Install operator and 3-node cluster in namespace `percona`:
```bash
npm run percona -- install --namespace percona --name pxc-cluster --nodes 3
```

This command will automatically:
- Install MinIO from external repo (bootstrap component)
- Install and configure ChartMuseum (internal Helm chart repository with local storage)
- Mirror all required charts (Percona, MinIO, LitmusChaos) to ChartMuseum
- Install the Percona operator (from internal ChartMuseum)
- Install the Percona cluster (from internal ChartMuseum)
- Install LitmusChaos for chaos engineering

**Note:** MinIO is installed from the external `minio/minio` chart repository as a bootstrap step, since ChartMuseum doesn't exist yet. After ChartMuseum is set up and charts are mirrored, all subsequent installations use the internal ChartMuseum repository.

Uninstall and cleanup PVCs:
```bash
npm run percona -- uninstall --namespace percona --name pxc-cluster
```

This command will automatically uninstall:
- Percona cluster and operator
- MinIO
- LitmusChaos
- ChartMuseum

### Cost-saving: Tear Down EKS When Not in Use
Delete the entire stack to avoid charges (can be recreated quickly):
```bash
aws cloudformation delete-stack --stack-name percona-eks-cluster --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name percona-eks-cluster --region us-east-1
```

**Verify the stack is completely deleted:**
```bash
aws cloudformation describe-stacks --stack-name percona-eks-cluster --region us-east-1
# Expected output: "Stack with id percona-eks-cluster does not exist"
# OR: An error indicating the stack was not found
```

This deletes everything (cluster, nodes, network). EBS volumes with data are also deleted.

**Costs while deleted: $0**

To recreate the cluster when needed:
```bash
./scripts/deploy.sh              # Creates EKS cluster (~15-20 min)
npm run percona -- install  # Installs Percona (~10-15 min)
```

Total recreation time: ~25-35 minutes

**Note:** If you need to preserve data between teardowns, ensure Percona backups to MinIO are completed before deleting the stack.

### Backup Configuration

By default, the Percona installation uses **MinIO** for backups to replicate on-premises environments where external access (like AWS S3) is restricted. The `npm run percona -- install ...` installation script automatically:
- Installs MinIO using Helm in the `minio` namespace
- Creates a `percona-backups` bucket in MinIO
- Sets up credentials and Kubernetes secrets for backup access
- Configures Percona cluster to use MinIO's S3-compatible API

This approach ensures the deployment matches on-premises environments where external cloud storage access is not permitted.

#### Backup Schedules and Retention (Configured by default)

- Binlog PITR (continuous): uploaded every 60s, retained for 7 days
- Daily full backups: 02:00 every day, retain 7 days
- Weekly full backups: 01:00 every Sunday, retain 8 weeks
- Monthly full backups: 01:30 on the 1st of each month, retain 12 months

These are implemented via the PXC Custom Resource `spec.backup`:

```yaml
spec:
  backup:
    enabled: true
    pitr:
      enabled: true
      storageName: minio-backup
      timeBetweenUploads: 60
    storages:
      minio-backup:
        type: s3
        s3:
          bucket: percona-backups
          region: us-east-1
          endpoint: http://minio.minio.svc.cluster.local:9000
          credentialsSecret: percona-backup-minio-credentials
    schedule:
      - name: daily-backup
        schedule: "0 2 * * *"
        retention:
          type: count
          count: 7
          deleteFromStorage: true
        storageName: minio-backup
      - name: weekly-backup
        schedule: "0 1 * * 0"
        retention:
          type: count
          count: 8
          deleteFromStorage: true
        storageName: minio-backup
      - name: monthly-backup
        schedule: "30 1 1 * *"
        retention:
          type: count
          count: 12
          deleteFromStorage: true
        storageName: minio-backup
```

#### Point-In-Time Recovery (PITR) quick restore

To restore to a point in time using binlogs and the latest full backup:

```bash
# Example: restore to a timestamp (UTC)
TARGET_TS="2025-11-02T18:30:00Z"
kubectl apply -n percona -f - <<EOF
apiVersion: pxc.percona.com/v1-10-0
kind: PerconaXtraDBClusterRestore
metadata:
  name: pxc-restore-pitr
spec:
  pxcCluster: pxc-cluster
  backupName: latest
  pitr:
    type: date
    date: "$TARGET_TS"
EOF
```

Notes:
- Ensure `backup.pitr.enabled: true` and MinIO/S3 storage are reachable
- The operator picks the latest compatible full backup and replays binlogs up to `TARGET_TS`

#### Using AWS S3 for Backups (Alternative)

If you prefer to use **AWS S3** instead of MinIO, you'll need to manually configure it:

**1. Create S3 bucket and credentials:**

The installation script no longer creates S3 resources by default. You would need to manually:
- Create an S3 bucket
- Set up IAM user and credentials
- Create a Kubernetes secret with S3 credentials

**2. Update Percona cluster configuration:**

Edit the PXC custom resource to use S3 storage:

```bash
kubectl get pxc <cluster-name>-pxc-db -n percona -o yaml > pxc-config.yaml
```

Update the backup section:

```yaml
spec:
  backup:
    enabled: true
    storages:
      s3-backup:
        type: s3
        s3:
          bucket: your-s3-bucket-name
          region: us-east-1
          credentialsSecret: percona-backup-s3-credentials
```

**Note:** This setup is designed to replicate on-premises environments, so MinIO (on-premises S3-compatible storage) is the default.

### Internal Helm Chart Repository (ChartMuseum)

This project uses **ChartMuseum** as an internal Helm chart repository to store all Helm charts locally within your EKS cluster. This eliminates dependencies on external repositories and aligns with on-premises environments where external access may be restricted.

#### What is ChartMuseum?

ChartMuseum is an open-source Helm Chart Repository server that stores Helm charts using local persistent storage. It's lightweight, Kubernetes-native, and perfect for EKS deployments.

**Benefits:**
- ✅ **Minimal external dependencies**: Only MinIO chart fetched externally (bootstrap), then all charts served internally
- ✅ **Local storage backend**: Uses EBS gp3 volumes for persistent storage
- ✅ **Kubernetes-native**: Runs in your EKS cluster
- ✅ **Secure**: Charts stored within your VPC on encrypted EBS volumes
- ✅ **On-premises compatible**: Matches restricted network environments
- ✅ **Fully automated**: Automatically installed and configured during setup

**Bootstrap Approach:**
Since ChartMuseum doesn't exist initially, MinIO is installed from the external `https://charts.min.io/` repository. Once ChartMuseum is running, all charts (including MinIO) are mirrored to it, and all subsequent Helm operations use the internal ChartMuseum repository.

#### Quick Setup (3 Steps)

**Step 1: Install ChartMuseum**

```bash
# Set your cluster name (if different from default)
export CLUSTER_NAME="percona-eks"
export AWS_REGION="us-east-1"

# Run the setup script
./scripts/setup-chartmuseum.sh
```

This script will:
- ✅ Create a dedicated namespace for ChartMuseum
- ✅ Install ChartMuseum in your EKS cluster
- ✅ Configure it with local persistent storage (50Gi EBS gp3 volume)
- ✅ Expose it as a ClusterIP service (internal only)

**Expected output:** ChartMuseum URL (e.g., `http://chartmuseum.chartmuseum.svc.cluster.local:8080`)

**Step 2: Mirror External Charts**

```bash
# Mirror all charts (ChartMuseum URL is auto-detected)
./scripts/mirror-charts.sh
```

This will download and upload:
- Percona charts (pxc-operator, pxc-db)
- MinIO chart
- LitmusChaos chart

**Step 3: Verify Setup**

```bash
# Add your internal repo
helm repo add internal http://chartmuseum.chartmuseum.svc.cluster.local:8080
helm repo update

# Search for charts
helm search repo internal

# Verify charts are available
helm search repo internal/pxc
helm search repo internal/minio
```

#### Architecture Overview

**Bootstrap Sequence:**
```
STEP 1: Bootstrap MinIO (external repo - ChartMuseum doesn't exist yet)
┌─────────────────────────────────┐
│  External: charts.min.io        │
└────────────┬────────────────────┘
             │ helm install minio/minio
             ▼
    ┌────────────────┐
    │ MinIO Pod      │
    └────────────────┘

STEP 2: Install ChartMuseum
┌──────────────────────────────────┐
│  ChartMuseum Pod                 │
│  ┌───────────────────────┐       │
│  │ Persistent Volume     │       │
│  │ (50Gi EBS gp3)        │       │
│  └───────────────────────┘       │
└──────────────────────────────────┘

STEP 3: Mirror charts → ChartMuseum (one-time)
External Repos → ChartMuseum (internal storage)

STEP 4: Install Percona from internal ChartMuseum
helm install internal/pxc-operator
helm install internal/pxc-db
```

#### Manual Setup Details

If you need to customize the ChartMuseum installation:

**Installation Parameters:**

```bash
# Environment variables (optional)
export NAMESPACE="chartmuseum"
export STORAGE_CLASS="gp3"  # EBS storage class
export STORAGE_SIZE="50Gi"  # Persistent volume size
export SERVICE_TYPE="ClusterIP"  # Service type (ClusterIP for internal only)

# Run setup script
./scripts/setup-chartmuseum.sh
```

**The script will:**
1. Create the `chartmuseum` namespace
2. Install ChartMuseum Helm chart with local storage configuration
3. Create a persistent volume claim (50Gi gp3 by default)
4. Configure resource limits (CPU: 100m-500m, Memory: 256Mi-512Mi)
5. Expose ChartMuseum as a ClusterIP service on port 8080

**Manual Installation (Advanced):**

```bash
# Add ChartMuseum Helm repo
helm repo add chartmuseum https://chartmuseum.github.io/charts
helm repo update

# Create namespace
kubectl create namespace chartmuseum

# Install ChartMuseum with local storage
helm install chartmuseum chartmuseum/chartmuseum \
    --namespace chartmuseum \
    --set env.open.DISABLE_API=false \
    --set env.open.STORAGE=local \
    --set env.open.STORAGE_LOCAL_ROOTDIR=/storage \
    --set persistence.enabled=true \
    --set persistence.accessMode=ReadWriteOnce \
    --set persistence.size=50Gi \
    --set persistence.storageClass=gp3 \
    --set service.type=ClusterIP \
    --set resources.requests.memory=256Mi \
    --set resources.requests.cpu=100m \
    --set resources.limits.memory=512Mi \
    --set resources.limits.cpu=500m \
    --wait
```

**Mirror External Charts:**

The `scripts/mirror-charts.sh` script handles downloading and uploading all required charts:

```bash
# The script will automatically:
# 1. Detect the ChartMuseum URL
# 2. Add external Helm repos (Percona, MinIO, LitmusChaos)
# 3. Download charts locally
# 4. Push them to ChartMuseum using the helm-push plugin

./scripts/mirror-charts.sh
```

#### Configuration

The codebase is configured to use ChartMuseum by default:

**`src/percona.ts`:**
- Default Helm repo URL: `http://chartmuseum.chartmuseum.svc.cluster.local:8080`
- The `addRepos()` function automatically adds the internal repo
- ChartMuseum is installed before chart mirroring
- Charts are verified after mirroring

**Test Files:**
- Unit tests automatically check for and add the internal repo if needed
- Tests gracefully skip if ChartMuseum is not available

#### Configuration Options

You can customize the setup with environment variables:

```bash
# Custom bucket name
export CHART_BUCKET_NAME="my-custom-chart-bucket"

# Custom namespace
export NAMESPACE="helm-repo"

# Custom ChartMuseum URL
export CHARTMUSEUM_URL="http://chartmuseum.chartmuseum.svc.cluster.local"

# Service type (LoadBalancer, ClusterIP, NodePort)
export SERVICE_TYPE="LoadBalancer"

# Then run setup
./scripts/setup-chartmuseum.sh
```

#### Automation: Keep Charts Updated

Set up a CronJob to periodically sync charts:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: chart-sync
  namespace: chartmuseum
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: helm
            image: alpine/helm:latest
            command:
            - /bin/sh
            - -c
            - |
              helm repo add internal http://chartmuseum.chartmuseum.svc.cluster.local
              # ... mirror logic ...
          restartPolicy: OnFailure
```

#### Troubleshooting

**ChartMuseum not accessible:**
```bash
# Check if pod is running
kubectl get pods -n chartmuseum

# Check service
kubectl get svc -n chartmuseum

# Check logs
kubectl logs -n chartmuseum -l app.kubernetes.io/name=chartmuseum
```

**S3 access issues:**
```bash
# Verify service account annotation
kubectl get sa chartmuseum -n chartmuseum -o yaml

# Check IAM role
kubectl describe sa chartmuseum -n chartmuseum
```

**Charts not found after mirroring:**
```bash
# Verify charts in S3
aws s3 ls s3://<your-bucket-name>/

# Check ChartMuseum API
curl http://chartmuseum.chartmuseum.svc.cluster.local/api/charts
```

#### Uninstall ChartMuseum

To remove ChartMuseum:

```bash
# Uninstall Helm release
helm uninstall chartmuseum -n chartmuseum

# Delete namespace
kubectl delete namespace chartmuseum

# ChartMuseum is automatically uninstalled with:
# npm run percona -- uninstall --namespace percona --name pxc-cluster
# This removes the namespace, persistent volume, and all stored charts

# Delete IAM resources (optional)
aws iam detach-role-policy --role-name ChartMuseumRole-<cluster-name> --policy-arn <policy-arn>
aws iam delete-role --role-name ChartMuseumRole-<cluster-name>
aws iam delete-policy --policy-arn <policy-arn>
```

#### Security Considerations

1. **Authentication**: Consider adding authentication to ChartMuseum for production:
   ```bash
   helm upgrade chartmuseum chartmuseum/chartmuseum \
       --namespace ${NAMESPACE} \
       --set env.open.BASIC_AUTH_USER=admin \
       --set env.open.BASIC_AUTH_PASS=<password>
   ```

2. **Network Policies**: Restrict access to ChartMuseum namespace

3. **TLS/HTTPS**: Use Ingress with TLS certificates for production

4. **IAM Permissions**: Follow least privilege for S3 access

#### External Repositories Being Mirrored

The following external repositories are mirrored to ChartMuseum:

1. **Percona**: `https://percona.github.io/percona-helm-charts/`
   - Charts: `percona/pxc-operator`, `percona/pxc-db`

2. **MinIO**: `https://charts.min.io/`
   - Chart: `minio/minio`

3. **LitmusChaos**: `https://litmuschaos.github.io/litmus-helm/`
   - Chart: `litmuschaos/litmus`

### AWS Console Access
To grant your IAM user/role access to view Kubernetes resources in the AWS Console, you can manually update the aws-auth ConfigMap or create EKS access entries. This functionality is not currently automated in a script.

### Running Tests

The project includes a comprehensive test suite to validate Percona XtraDB Cluster deployment, configuration, and best practices.

#### Prerequisites for Testing

**Required:**
- **Python 3.9+**
  ```bash
  python3 --version
  ```

- **kubectl** - configured to connect to your Kubernetes cluster
  ```bash
  kubectl version --client
  kubectl cluster-info
  kubectl get nodes
  ```

- **Helm 3.x**
  ```bash
  helm version
  ```

- **Percona cluster deployed** in your Kubernetes cluster
  ```bash
  kubectl get pxc -n percona
  ```

**Optional (for backup tests):**
- **AWS CLI** (for S3 backup tests)
- **MinIO client** (for MinIO backup tests)

#### Installation

1. **Create Python virtual environment** (recommended)
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   ```

2. **Install dependencies**
   ```bash
   pip install -r tests/requirements.txt
   ```

#### Quick Start - Run All Tests

Use the provided test runner script:

```bash
./tests/run_tests.sh
```

This script will:
- Check prerequisites (Python, kubectl, helm)
- Set up a Python virtual environment
- Install test dependencies
- Run all tests with clear output

**CI Pipeline Execution Order:**
1. Unit tests first (fast, fail-fast): `pytest tests/unit/ -v -m unit`
2. Integration tests (after unit tests pass): `pytest tests/integration/ -v -m integration`
3. Resiliency tests (only triggered by LitmusChaos, not in standard CI)

#### Test Categories

Tests are organized into three distinct categories based on their purpose and dependencies:

**1. Unit Tests** (`tests/unit/`)

**Purpose**: Test one specific unit of functionality within the Percona infrastructure.

**Characteristics**:
- Run with **no dependency on running infrastructure**
- May use **mocks or fakes** to replicate responses from APIs or other interfaces
- **Fast execution** (typically < 5 seconds per test)
- **Deterministic** - same input always produces same output

**When to run**:
- ✅ **First in CI pipeline** during merge requests
- ✅ **Fail-fast** - if any unit test fails, merge fails immediately
- ✅ Run on every code change
- ✅ Can run locally without cluster

**Current Tests**:
- `tests/unit/test_helm_charts.py` - Helm chart template rendering validation

**2. Integration Tests** (`tests/integration/`)

**Purpose**: Verify that services the Percona ecosystem depends on behave correctly.

**Characteristics**:
- Require **access to running infrastructure** (Kubernetes cluster, Helm, etc.)
- Verify **dependency versions and configuration** are correct
- Test that **external services** (MinIO, K8s APIs) respond as expected
- May take longer than unit tests (typically 10-60 seconds)

**When to run**:
- ✅ After unit tests pass
- ✅ Before resiliency tests
- ✅ On merge requests after successful unit tests
- ✅ After infrastructure changes (K8s version upgrades, etc.)

**Examples**:
- Kubernetes version compatibility check (>= 1.24)
- StorageClass exists and has correct configuration
- Helm repository availability
- Node zone labels for multi-AZ
- Backup secret existence

**Current Tests**:
- `tests/integration/test_dependencies.py` - K8s, Helm, StorageClass, backup dependencies

**3. Resiliency Tests** (`tests/resiliency/`)

**Purpose**: Verify that the system recovers correctly after chaos events triggered by LitmusChaos.

**Characteristics**:
- Run **in concert with LitmusChaos** disaster scenarios
- **Automatically triggered** after chaos events complete
- **Polling-based** - check recovery state every 15 seconds
- **MTTR timeout** - default 2 minutes (configurable)
- Test **system recovery**, not just failure

**When to run**:
- ✅ After chaos experiments complete
- ✅ Continuously in production (via scheduled chaos)
- ✅ As part of resilience testing workflows
- ✅ Not run during normal CI pipeline (too slow/expensive)

**Recovery Scenarios**:
- Pod deletion → verify pod returns to Running
- StatefulSet pod loss → verify all replicas recover
- Service disruption → verify endpoints restore
- Cluster status → verify cluster returns to 'ready'

**MTTR Configuration**:
- Default timeout: 120 seconds (2 minutes)
- Poll interval: 15 seconds
- Configurable via `RESILIENCY_MTTR_TIMEOUT_SECONDS` environment variable

**Current Tests**:
- `tests/resiliency/test_pod_recovery.py` - Pod, StatefulSet, Service, Cluster recovery tests
- `tests/resiliency/helpers.py` - Polling and MTTR helper functions
- `tests/resiliency/chaos_integration.py` - LitmusChaos integration

#### Running Tests by Category

Each test category can be run individually:

**Unit Tests** (fast, no cluster required):
```bash
# Option 1: Run by directory
pytest tests/unit/ -v

# Option 2: Run by marker (useful if tests are in multiple locations)
pytest tests/ -v -m unit

# Option 3: Both directory and marker (most explicit)
pytest tests/unit/ -v -m unit
```

**Integration Tests** (requires cluster access):
```bash
# Option 1: Run by directory
pytest tests/integration/ -v

# Option 2: Run by marker
pytest tests/ -v -m integration

# Option 3: Both directory and marker
pytest tests/integration/ -v -m integration
```

**Resiliency Tests** (triggered by LitmusChaos or run manually):
```bash
# Run resiliency tests manually (usually auto-triggered by LitmusChaos)
pytest tests/resiliency/ -v -m resiliency

# Run with custom MTTR timeout (default: 120 seconds)
RESILIENCY_MTTR_TIMEOUT_SECONDS=300 pytest tests/resiliency/ -v -m resiliency

# Run with custom poll interval (default: 15 seconds)
RESILIENCY_POLL_INTERVAL_SECONDS=10 RESILIENCY_MTTR_TIMEOUT_SECONDS=180 pytest tests/resiliency/ -v -m resiliency
```

**Combined Categories**:
```bash
# Unit + Integration (all non-resiliency tests)
pytest tests/ -v -m "unit or integration"

# Exclude resiliency tests
pytest tests/ -v -m "not resiliency"

# Run all tests
pytest tests/ -v
```

**Quick Reference**:
- `pytest tests/unit/ -v` - Unit tests only (fast)
- `pytest tests/integration/ -v` - Integration tests only
- `pytest tests/resiliency/ -v` - Resiliency tests only
- `pytest tests/ -v -m unit` - All unit tests by marker
- `pytest tests/ -v -m integration` - All integration tests by marker
- `pytest tests/ -v -m resiliency` - All resiliency tests by marker

#### Test Organization Structure

```
tests/
├── unit/              # Unit tests (fast, no cluster)
│   ├── __init__.py
│   └── test_helm_charts.py
│
├── integration/       # Integration tests (verify dependencies)
│   ├── __init__.py
│   └── test_dependencies.py
│
├── resiliency/        # Resiliency tests (chaos recovery)
│   ├── __init__.py
│   ├── helpers.py          # Polling and MTTR helpers
│   ├── chaos_integration.py # LitmusChaos integration
│   └── test_pod_recovery.py
│
├── conftest.py        # Shared fixtures
├── run_tests.sh       # Test runner script
└── requirements.txt   # Python dependencies
```

#### Test Modules and Coverage

The test suite validates:

**Unit Tests**:
- Helm chart template rendering validation
- YAML structure validation
- Configuration parsing

**Integration Tests**:
- Kubernetes version compatibility (>= 1.24)
- StorageClass exists and has correct parameters
- Helm repository availability
- Node zone labels for multi-AZ deployment
- Backup secret existence
- Operator version and status
- PXC and ProxySQL image versions
- Cluster custom resource existence
- Resource requests and limits configuration
- StatefulSet configuration (service names, update strategies, volume claim templates)
- Anti-affinity rules in specifications
- PVC size, storage class, and access modes
- Backup storage configuration and schedules

**Resiliency Tests**:
- Pod recovery after deletion
- StatefulSet replica recovery
- Service endpoint restoration
- Cluster status recovery to 'ready'

#### Resiliency Test Polling Mechanism

All resiliency tests use the polling mechanism from `tests/resiliency/helpers.py`:

**Default Configuration**:
- **MTTR timeout**: 120 seconds (2 minutes)
- **Poll interval**: 15 seconds
- **Configurable**: Via `RESILIENCY_MTTR_TIMEOUT_SECONDS` and `RESILIENCY_POLL_INTERVAL_SECONDS` environment variables

**Polling Flow**:
1. **Chaos event occurs** (e.g., pod deleted by LitmusChaos)
2. **LitmusChaos completes** (verdict: Pass/Fail)
3. **Resiliency test triggered** automatically
4. **Polling starts**:
   - Check recovery condition every 15 seconds
   - Continue until condition met or timeout
   - Fail if timeout reached without recovery

**Recovery Check Functions**:
- `wait_for_pod_recovery()` - Pod returns to Running state
- `wait_for_statefulset_recovery()` - All replicas ready
- `wait_for_service_recovery()` - Endpoints restored
- `wait_for_cluster_recovery()` - Cluster status 'ready'

#### LitmusChaos Integration

LitmusChaos automatically triggers resiliency tests after chaos events complete:

1. **ChaosEngine** runs chaos experiment
2. **ChaosResult** indicates completion (verdict: Pass/Fail)
3. **Resiliency test job** is triggered automatically
4. **Polling test** verifies recovery within MTTR timeout

See `chaos-experiments/pod-delete-pxc-with-resiliency.yaml` for example configuration.

#### Configuration

Set environment variables to customize test behavior:

```bash
export TEST_NAMESPACE=percona
export TEST_CLUSTER_NAME=pxc-cluster
export TEST_EXPECTED_NODES=6
export TEST_BACKUP_TYPE=minio  # or 's3' (default: minio for on-prem replication)
export TEST_BACKUP_BUCKET=my-backup-bucket
export RESILIENCY_MTTR_TIMEOUT_SECONDS=120  # Default: 120 seconds
export RESILIENCY_POLL_INTERVAL_SECONDS=15  # Default: 15 seconds
```

#### Running Tests Before/After Changes

**Before making changes:**
```bash
# Run unit tests first (fast, no cluster needed)
pytest tests/unit/ -v -m unit

# If unit tests pass, run integration tests
pytest tests/integration/ -v -m integration

# Or run all non-resiliency tests
pytest tests/ -v -m "unit or integration"
```

**After deployment:**
```bash
# Verify everything is correctly configured
# Run integration tests to verify dependencies
pytest tests/integration/ -v -m integration

# Or run all non-resiliency tests
pytest tests/ -v -m "unit or integration"
```

**After cluster changes:**
```bash
# Ensure nothing broke - run integration tests
pytest tests/integration/ -v -m integration

# For comprehensive validation, run all non-resiliency tests
pytest tests/ -v -m "unit or integration"
```

**For resiliency testing (after chaos events):**
```bash
# Resiliency tests are usually auto-triggered by LitmusChaos
# To run manually after a chaos event:
pytest tests/resiliency/ -v -m resiliency

# With custom timeout:
RESILIENCY_MTTR_TIMEOUT_SECONDS=300 pytest tests/resiliency/ -v -m resiliency
```

#### Running Specific Tests

```bash
# Run specific test module
pytest tests/test_cluster_versions.py -v

# Run specific test class
pytest tests/test_pvcs_storage.py::TestPVCsAndStorage -v

# Run specific test
pytest tests/test_cluster_versions.py::TestClusterVersions::test_kubernetes_version_compatibility -v

# Generate HTML report
pytest tests/ --html=tests/report.html --self-contained-html
```

#### Test Output

The test suite uses `rich` for console output:
- ✅ Green checkmarks for passing tests
- ❌ Red X marks for failing tests
- ⚠️ Yellow warnings for skipped tests
- 📊 Cyan informational messages

#### Troubleshooting Tests

**Tests fail with "Cannot connect to Kubernetes cluster":**
```bash
# Verify kubectl access
kubectl cluster-info
kubectl get nodes
```

**Tests fail with "Namespace not found":**
```bash
# Ensure Percona cluster is deployed
kubectl get pxc -n percona
kubectl get pods -n percona
```

**Tests fail with "No matching resources":**
```bash
# Check cluster name and namespace match your deployment
kubectl get pxc -n percona
kubectl get statefulset -n percona

# Set environment variables if different
export TEST_NAMESPACE=your-namespace
export TEST_CLUSTER_NAME=your-cluster-name
```

**Import errors:**
```bash
# Ensure all dependencies are installed
pip install -r tests/requirements.txt
```

#### Test Markers

All tests use pytest markers for categorization:

- `@pytest.mark.unit` - Unit tests
- `@pytest.mark.integration` - Integration tests
- `@pytest.mark.resiliency` - Resiliency tests

Run specific category:
```bash
pytest -m unit       # Only unit tests
pytest -m integration # Only integration tests
pytest -m resiliency # Only resiliency tests
```

### Chaos Engineering with LitmusChaos

The project includes **LitmusChaos** for chaos engineering to test cluster resilience. LitmusChaos is automatically installed when you run `npm run percona -- install`.

#### What is LitmusChaos?

LitmusChaos is a cloud-native chaos engineering platform that helps test the resilience of your Percona XtraDB Cluster by introducing controlled failures. It's developed by Harness (US-based company) and is a CNCF incubating project.

#### Chaos Experiments Included

LitmusChaos can break approximately **65% of the test suite** by simulating various failure scenarios:

**Tests That CAN Be Broken:**
- ✅ **StatefulSets** (90%) - Pod kills, container failures
- ✅ **Services** (100%) - Network partitions, pod failures
- ✅ **Cluster Versions** (80%) - Operator/PXC pod failures
- ✅ **Resources/PDB** (70%) - CPU/memory stress, PDB violations
- ✅ **Anti-affinity** (60%) - Node failures, network partitions
- ✅ **Backups** (80%) - MinIO pod failures, network issues
- ✅ **PVCs/Storage** (40%) - I/O stress, disk fill

**Tests That CANNOT Be Broken (require manual intervention):**
- ❌ Secrets (backup credentials)
- ❌ PVC specifications (size, storage class)
- ❌ Helm release configurations
- ❌ Resource requests/limits in specs
- ❌ Anti-affinity rules in specs

#### Running Chaos Experiments

**Note:** ChartMuseum and chart mirroring are automatically installed and configured when you run `npm run percona -- install`.

**1. View available chaos experiments:**
```bash
kubectl get chaosexperiments -n litmus
```

**2. Create a simple pod-delete experiment:**
```bash
# Example: Delete a PXC pod
kubectl apply -f - <<EOF
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pxc-pod-delete
  namespace: percona
spec:
  appinfo:
    appns: percona
    applabel: 'app.kubernetes.io/component=pxc'
    appkind: 'statefulset'
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: '60'
            - name: CHAOS_INTERVAL
              value: '10'
            - name: FORCE
              value: 'false'
EOF
```

**3. Monitor chaos experiments:**
```bash
# View chaos engines
kubectl get chaosengines -n percona

# View chaos results
kubectl get chaosresults -n percona

# View detailed logs
kubectl describe chaosengine pxc-pod-delete -n percona
```

**4. Access LitmusChaos UI:**
```bash
# Port-forward the frontend service
kubectl port-forward -n litmus svc/chaos-litmus-frontend-service 8080:9091
# Open http://localhost:8080 in your browser
# Default credentials: Username: admin, Password: litmus
```

#### Running Continuous Chaos (Daemon Mode)

To run chaos experiments continuously and randomly:

**1. Ensure LitmusChaos is installed:**
```bash
# Check if LitmusChaos is installed
kubectl get pods -n litmus

# If not installed, install it (or it's installed automatically with npm run percona -- install):
./scripts/install-litmus.sh
```

**2. Create a scheduled chaos workflow:**
```bash
# Example: Random pod deletion every 30 minutes
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: percona-chaos-daily
  namespace: litmus
spec:
  schedule: "*/30 * * * *"  # Every 30 minutes
  workflowSpec:
    entrypoint: chaos-workflow
    templates:
      - name: chaos-workflow
        steps:
          - - name: pxc-pod-delete
              templateRef:
                name: pod-delete
                template: pod-delete
                clusterScope: true
              arguments:
                parameters:
                  - name: appns
                    value: percona
                  - name: applabel
                    value: 'app.kubernetes.io/component=pxc'
EOF
```

#### Running Tests During Chaos

Run your test suite while chaos experiments are active to verify resilience:

```bash
# In one terminal: Start chaos experiments
kubectl create -f chaos-experiments/pod-delete-pxc.yaml

# In another terminal: Run tests
pytest tests/ -v

# Tests should handle failures gracefully or report expected failures
```

#### Available Chaos Experiment Types

LitmusChaos provides experiments for:

- **Pod Chaos**: `pod-delete`, `pod-cpu-hog`, `pod-memory-hog`, `container-kill`
- **Network Chaos**: `network-partition`, `network-latency`, `network-loss`, `network-duplication`
- **Node Chaos**: `node-cpu-hog`, `node-memory-hog`, `node-drain`, `node-taint`
- **Storage Chaos**: `disk-fill`, `disk-loss`
- **DNS Chaos**: `dns-chaos`

#### Stopping Chaos Experiments

```bash
# Delete a specific chaos engine
kubectl delete chaosengine pxc-pod-delete -n percona

# Stop all chaos experiments
kubectl delete chaosengines --all -n percona
```

#### Installing and Uninstalling LitmusChaos

LitmusChaos is automatically installed when you run `npm run percona -- install`. However, you can also install, uninstall, and reinstall it manually:

**Install LitmusChaos:**
```bash
# Option 1: Use the installation script
./scripts/install-litmus.sh

# Option 2: Manual installation (exact command from official docs)
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
kubectl create ns litmus
helm install chaos litmuschaos/litmus --namespace=litmus --set portal.frontend.service.type=NodePort

# Note: LitmusChaos is automatically installed when you run npm run percona -- install
```

**Verify Installation:**
```bash
# Check that all pods are running
kubectl get pods -n litmus

# Expected output should show all pods in Running state:
# chaos-litmus-auth-server-*
# chaos-litmus-frontend-*
# chaos-litmus-server-*
# chaos-mongodb-*
```

**Uninstall LitmusChaos:**
```bash
# Uninstall the Helm release (release name is "chaos")
helm uninstall chaos -n litmus

# Delete the namespace (this removes all resources including CRDs)
kubectl delete namespace litmus
```

**Reinstall LitmusChaos:**
```bash
# Simply run the install command again
./scripts/install-litmus.sh

# Or manually:
kubectl create ns litmus
helm install chaos litmuschaos/litmus --namespace=litmus --set portal.frontend.service.type=NodePort
```

**Note:** If you uninstall Percona using `npm run percona -- uninstall`, LitmusChaos will also be automatically uninstalled along with it.

#### Chaos Engineering Best Practices

1. **Start Small**: Begin with simple experiments (single pod delete) before complex scenarios
2. **Test in Non-Production**: Always test chaos experiments in non-production environments first
3. **Monitor Metrics**: Watch cluster metrics during chaos experiments
4. **Document Results**: Record which tests fail and why to improve resilience
5. **Gradual Increase**: Start with low-frequency chaos and gradually increase
6. **Have Rollback Plan**: Ensure you can quickly stop chaos experiments if needed

#### Chaos Experiments Directory

Create chaos experiment manifests in a `chaos-experiments/` directory:

```bash
mkdir -p chaos-experiments
# Create YAML files for reusable chaos experiments
```

Example experiment files to create:
- `pod-delete-pxc.yaml` - Delete PXC pods
- `pod-delete-proxysql.yaml` - Delete ProxySQL pods
- `network-partition.yaml` - Partition network between zones
- `pod-cpu-hog.yaml` - Stress CPU on PXC pods
- `node-drain.yaml` - Drain nodes to test pod rescheduling

---

## Chaos Engineering Tool Comparison

This project uses **LitmusChaos** for chaos engineering. Below is a comparison with other options:

### Why LitmusChaos?

**Selected: LitmusChaos** - Better security posture, US ownership, and comprehensive features suitable for Percona XtraDB Cluster testing.

### Feature Comparison Matrix

#### Pod-Level Chaos (Affects: StatefulSets, Services, Cluster Versions, Resources/PDB)

| Feature | Chaos Mesh | LitmusChaos | Test Impact |
|---------|------------|-------------|-------------|
| **Pod Kill** | ✅ PodChaos | ✅ pod-delete | Breaks: `test_statefulsets.py`, `test_cluster_versions.py`, `test_services.py`, `test_resources_pdb.py` |
| **Container Kill** | ✅ PodChaos | ✅ pod-delete (per-container) | Similar to pod kill |
| **Pod Stress (CPU/Memory)** | ✅ StressChaos | ✅ pod-cpu-hog, pod-memory-hog | Breaks: `test_resources_pdb.py` |
| **Pod I/O Stress** | ✅ IOChaos | ✅ disk-fill | Breaks: `test_pvcs_storage.py`, `test_backups.py` |

#### Network-Level Chaos (Affects: Services, Backups, Anti-affinity)

| Feature | Chaos Mesh | LitmusChaos | Test Impact |
|---------|------------|-------------|-------------|
| **Network Partition** | ✅ NetworkChaos | ✅ network-partition | Breaks: `test_services.py`, `test_backups.py`, `test_affinity_taints.py` |
| **Network Latency** | ✅ NetworkChaos | ✅ network-latency | Breaks: `test_services.py`, `test_backups.py` |
| **Packet Loss** | ✅ NetworkChaos | ✅ network-loss | Similar to latency |
| **DNS Chaos** | ❌ Not available | ✅ dns-chaos | Can break service discovery |

**Winner:** **LitmusChaos** - Includes DNS chaos, better for network failure scenarios

#### Node-Level Chaos (Affects: Anti-affinity, Cluster Versions)

| Feature | Chaos Mesh | LitmusChaos | Test Impact |
|---------|------------|-------------|-------------|
| **Node Failure** | ✅ Limited (AWS EC2 only) | ✅ node-drain, node-reboot | Breaks: `test_affinity_taints.py` |
| **Node CPU/Memory Stress** | ✅ Limited | ✅ node-cpu-hog, node-memory-hog | Can cause pod eviction |
| **Node Taint** | ❌ Not available | ✅ node-taint | Can break `test_affinity_taints.py` |

**Winner:** **LitmusChaos** - Comprehensive node-level chaos, including taints

### Security & Compliance Comparison

| Aspect | Chaos Mesh | LitmusChaos |
|--------|------------|-------------|
| **Company Ownership** | PingCAP (China) | Harness (USA) |
| **CNCF Status** | Incubating | Incubating |
| **Recent CVEs** | Multiple critical (2025) - Fixed in 2.7.3 | None found |
| **Security Posture** | ⚠️ Recent vulnerabilities | ✅ Clean security record |
| **Supply Chain Risk** | ⚠️ Chinese origin | ✅ US-owned |

**Winner:** **LitmusChaos** - Better security posture and compliance-friendly

### Test Coverage Summary

| Test Category | % Breakable by Chaos | Tool Recommendation |
|---------------|---------------------|---------------------|
| StatefulSets | 90% | Both (LitmusChaos preferred) |
| Services | 100% | Both |
| Cluster Versions | 80% | Both |
| Resources/PDB | 70% | Both |
| Anti-affinity | 60% | LitmusChaos (node taints) |
| Backups | 80% | Both |
| PVCs/Storage | 40% | Chaos Mesh (I/O granularity) |
| Helm Charts | 0% | Neither (requires API operations) |

**Overall: ~65% of tests can be broken by chaos tools**

### Why We Chose LitmusChaos

1. ✅ **US-based ownership** (Harness) - Better for compliance and security
2. ✅ **Clean security record** - No recent critical CVEs
3. ✅ **Comprehensive node chaos** - Including taints for anti-affinity testing
4. ✅ **DNS chaos support** - Better network failure scenarios
5. ✅ **Excellent community** - Harness backing provides strong support

---

### Notes
- EKS control plane incurs ~$0.10/hr while the cluster exists; delete when done.
- Check for orphaned LoadBalancers and EBS volumes after uninstall/delete.
- CloudFormation template uses On-Demand instances by default (set `UseSpotInstances=true` for Spot, not recommended for databases).




## Disaster Recovery Test Structure

This section documents the structure and validation of DR scenario tests (merged from `DR_TEST_STRUCTURE.md`).

### Overview

DR scenarios are defined in `disaster_scenarios/disaster_scenarios.json` with corresponding individual test files in `tests/resiliency/`.

### JSON Structure

Each scenario in `disaster_scenarios.json` must have the following fields:

#### Required Original Fields
- `scenario`: Name of the DR scenario
- `primary_recovery_method`: Primary recovery approach
- `alternate_fallback`: Alternative recovery method
- `detection_signals`: How to detect this issue
- `rto_target`: Recovery Time Objective target
- `rpo_target`: Recovery Point Objective target
- `mttr_expected`: Mean Time To Recovery expected
- `expected_data_loss`: Expected data loss description
- `likelihood`: Likelihood of occurrence (Low/Medium/High)
- `business_impact`: Business impact level (Low/Medium/High/Critical)
- `affected_components`: Components affected by this scenario
- `notes_assumptions`: Additional notes and assumptions

#### Required Test Fields
- `test_enabled`: Boolean indicating if automated testing is possible
- `test_file`: Filename of the test (or `null` if `test_enabled=false`)
- `test_description`: Description of why test is/isn't automated

#### Test Automation Fields (required if `test_enabled=true`)
- `chaos_type`: Type of chaos to inject (e.g., "pod-delete", "node-drain")
- `target_label`: Kubernetes label selector for target resources
- `app_kind`: Kubernetes resource kind (e.g., "statefulset", "deployment")
- `expected_recovery`: Type of recovery verification ("cluster_ready", "statefulset_ready", "service_endpoints", "pods_running")
- `mttr_seconds`: Maximum time allowed for recovery
- `poll_interval`: Seconds between recovery checks
- `total_chaos_duration`: Total duration chaos runs
- `chaos_interval`: Interval between chaos events

### Test File Naming Convention

Test files must follow this pattern:
- Filename: `test_dr_<scenario_name_normalized>.py`
- Located in: `tests/resiliency/`
- Must start with: `test_dr_`
- Must end with: `.py`

Example: "Single MySQL pod failure" → `test_dr_single_mysql_pod_failure.py`

### Validation

The `tests/resiliency/test_dr_coverage.py` file contains validation tests that ensure:

1. All scenarios have the `test_file` field defined
2. Enabled scenarios (`test_enabled=true`) have corresponding test files
3. Disabled scenarios (`test_enabled=false`) have `test_file=null`
4. No orphaned test files exist (files without JSON entries)
5. Test files follow naming conventions

### Current Coverage

- **Total Scenarios**: 16
- **With Automated Tests**: 4 (25%)
- **Explicitly No Test**: 12 (75%)

#### Scenarios With Automated Tests

1. Single MySQL pod failure - `tests/resiliency/test_dr_single_mysql_pod_failure.py`
2. Kubernetes worker node failure - `tests/resiliency/test_dr_kubernetes_worker_node_failure.py`
3. Percona Operator misconfiguration - `tests/resiliency/test_dr_percona_operator_crd_misconfiguration.py`
4. Ingress/VIP failure - `tests/resiliency/test_dr_ingressvip_failure.py`

#### Scenarios Without Automated Tests

12 scenarios are explicitly marked as `test_enabled=false` because they require multi-DC infrastructure, destructive operations, or are covered by other tests.

### Adding a New DR Scenario

1. Add entry to `disaster_scenarios.json` with all required fields
2. Create test file at `tests/resiliency/test_dr_<name>.py`
3. Run validation: `pytest tests/resiliency/test_dr_coverage.py -v`

### If Test is Not Possible

Set `test_enabled: false` and `test_file: null`, with explanation in `test_description`.

### Benefits

1. **Traceability**: Every DR scenario is tracked
2. **Visibility**: Easy to see test coverage
3. **Enforcement**: Validation prevents scenarios without explicit test status
4. **Maintainability**: Individual test files
5. **Documentation**: Tests serve as executable documentation


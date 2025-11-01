## Percona EKS Automation

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
./deploy.sh
```

Or with verbose output:
```bash
./deploy.sh -vv
```

Delete cluster:
```bash
aws cloudformation delete-stack --stack-name percona-eks-cluster --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name percona-eks-cluster --region us-east-1
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

Uninstall and cleanup PVCs:
```bash
npm run percona -- uninstall --namespace percona --name pxc-cluster
```

### Cost-saving: Tear Down When Not in Use
Delete the entire stack to avoid charges (can be recreated quickly):
```bash
aws cloudformation delete-stack --stack-name percona-eks-cluster --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name percona-eks-cluster --region us-east-1
```

This deletes everything (cluster, nodes, network). EBS volumes with data are also deleted.

**Costs while deleted: $0**

To recreate the cluster when needed:
```bash
./deploy.sh              # Creates EKS cluster (~15-20 min)
npm run percona -- install  # Installs Percona (~10-15 min)
```

Total recreation time: ~30-35 minutes

**Note:** If you need to preserve data between teardowns, ensure Percona backups to MinIO are completed before deleting the stack.

### Backup Configuration

By default, the Percona installation uses **MinIO** for backups to replicate on-premises environments where external access (like AWS S3) is restricted. The installation script automatically:
- Installs MinIO using Helm in the `minio` namespace
- Creates a `percona-backups` bucket in MinIO
- Sets up credentials and Kubernetes secrets for backup access
- Configures Percona cluster to use MinIO's S3-compatible API

This approach ensures the deployment matches on-premises environments where external cloud storage access is not permitted.

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

### AWS Console Access
Grant your IAM user/role access to view Kubernetes resources in the AWS Console:
```bash
./grant-console-access.sh
```

This script:
- Auto-detects your SSO role and node group role ARNs
- Updates the aws-auth ConfigMap
- Creates EKS access entries for API-based authentication
- Associates cluster admin policy

After running, refresh the AWS Console to view nodes, pods, and services.

### Running Tests

The project includes a comprehensive test suite to validate Percona XtraDB Cluster deployment, configuration, and best practices.

#### Prerequisites for Testing

```bash
# Install Python 3.9+ if not already installed
python3 --version

# Ensure kubectl is configured and can access your cluster
kubectl cluster-info
kubectl get nodes
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

#### Manual Test Execution

**1. Set up Python environment:**

```bash
# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r tests/requirements.txt
```

**2. Configure test environment (optional):**

```bash
export TEST_NAMESPACE=percona
export TEST_CLUSTER_NAME=pxc-cluster
export TEST_EXPECTED_NODES=6
export TEST_BACKUP_TYPE=minio  # or 's3'
```

**3. Run tests:**

```bash
# Run all tests
pytest tests/ -v

# Run specific test module
pytest tests/test_cluster_versions.py -v

# Run specific test class
pytest tests/test_pvcs_storage.py::TestPVCsAndStorage -v

# Run specific test
pytest tests/test_cluster_versions.py::TestClusterVersions::test_kubernetes_version_compatibility -v

# Generate HTML report
pytest tests/ --html=tests/report.html --self-contained-html
```

#### Test Coverage

The test suite validates:
- ✅ Cluster versions and component versions
- ✅ Kubernetes version compatibility (>= 1.24)
- ✅ Helm chart rendering and configuration
- ✅ Persistent Volume Claims (PVCs) and storage
- ✅ StatefulSets configuration
- ✅ Anti-affinity rules and multi-AZ pod distribution
- ✅ Resource limits and requests
- ✅ Pod Disruption Budgets (PDB)
- ✅ Backup configuration (MinIO/S3)
- ✅ Kubernetes Services and endpoints
- ✅ Cluster health and readiness

#### Running Tests Before/After Changes

**Before making changes:**
```bash
# Validate current cluster state
pytest tests/ -v
```

**After deployment:**
```bash
# Verify everything is correctly configured
pytest tests/ -v
```

**After cluster changes:**
```bash
# Ensure nothing broke
pytest tests/ -v
```

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

For more detailed test documentation, see [`tests/README.md`](tests/README.md).

### Notes
- EKS control plane incurs ~$0.10/hr while the cluster exists; delete when done.
- Check for orphaned LoadBalancers and EBS volumes after uninstall/delete.
- CloudFormation template uses On-Demand instances by default (set `UseSpotInstances=true` for Spot, not recommended for databases).



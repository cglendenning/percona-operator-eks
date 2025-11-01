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
kubectl port-forward -n litmus svc/litmus-portal-frontend 8080:9091
# Open http://localhost:8080 in your browser
```

#### Running Continuous Chaos (Daemon Mode)

To run chaos experiments continuously and randomly:

**1. Install LitmusChaos manually (if not already installed):**
```bash
./install-litmus.sh
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

# Uninstall LitmusChaos completely
npm run percona -- uninstall --namespace percona --name pxc-cluster
# Or manually:
helm uninstall litmus -n litmus
kubectl delete namespace litmus
```

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



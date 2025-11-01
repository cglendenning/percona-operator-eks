# Percona XtraDB Cluster Test Suite

Comprehensive test suite for validating Percona XtraDB Cluster deployments on Kubernetes.

## Overview

This test suite validates all aspects of a Percona XtraDB Cluster deployment:
- Cluster versions and component versions
- Helm chart rendering and configuration
- Persistent Volume Claims (PVCs) and storage
- StatefulSets configuration
- Anti-affinity rules and pod distribution
- Taints and tolerations
- Backup configuration (S3/MinIO)
- Resource limits and requests
- Pod Disruption Budgets (PDB)
- Kubernetes Services
- Cluster health and readiness

## Prerequisites

### For Local Testing (Mac)

1. **Python 3.9+**
   ```bash
   python3 --version
   ```

2. **kubectl** - configured to connect to your Kubernetes cluster
   ```bash
   kubectl version --client
   kubectl cluster-info
   ```

3. **Helm 3.x**
   ```bash
   helm version
   ```

4. **Percona cluster deployed** in your Kubernetes cluster
   ```bash
   kubectl get pxc -n percona
   ```

### Optional for Backup Tests

- **AWS CLI** (for S3 backup tests)
  ```bash
  aws --version
  ```

- **MinIO client** (for MinIO backup tests)
  ```bash
  mc --version
  ```

## Installation

1. **Create Python virtual environment** (recommended)
   ```bash
   cd /path/to/percona_operator
   python3 -m venv venv
   source venv/bin/activate
   ```

2. **Install dependencies**
   ```bash
   pip install -r tests/requirements.txt
   ```

## Running Tests

### Quick Start

Use the provided test runner script:

```bash
chmod +x tests/run_tests.sh
./tests/run_tests.sh
```

### Manual Execution

Run all tests:
```bash
pytest tests/ -v
```

Run specific test module:
```bash
pytest tests/test_cluster_versions.py -v
```

Run specific test class:
```bash
pytest tests/test_pvcs_storage.py::TestPVCsAndStorage -v
```

Run specific test:
```bash
pytest tests/test_cluster_versions.py::TestClusterVersions::test_kubernetes_version_compatibility -v
```

### Configuration

Set environment variables to customize test behavior:

```bash
export TEST_NAMESPACE=percona
export TEST_CLUSTER_NAME=pxc-cluster
export TEST_EXPECTED_NODES=6
export TEST_BACKUP_TYPE=s3  # or 'minio'
export TEST_BACKUP_BUCKET=my-backup-bucket
```

Then run tests:
```bash
pytest tests/ -v
```

### Generate HTML Report

```bash
GENERATE_HTML_REPORT=true ./tests/run_tests.sh
# or
pytest tests/ --html=tests/report.html --self-contained-html
```

## Test Modules

### `test_cluster_versions.py`
- Kubernetes version compatibility
- Operator version and status
- PXC and ProxySQL image versions
- Cluster custom resource status
- Cluster readiness

### `test_helm_charts.py`
- Helm repo availability
- Chart rendering
- Helm release validation
- Chart values verification
- Resource rendering (StatefulSets, PVCs)
- Anti-affinity rules in charts

### `test_pvcs_storage.py`
- PVC existence and binding
- Storage class configuration
- Storage sizes
- Access modes
- Storage class parameters (encryption, etc.)

### `test_statefulsets.py`
- StatefulSet existence
- Replica counts
- Service names
- Update strategies
- Volume claim templates

### `test_affinity_taints.py`
- Pod anti-affinity rules
- Topology key configuration
- Multi-AZ pod distribution
- Node zone labels
- Tolerations

### `test_backups.py`
- Backup secret existence
- Backup storage configuration
- Backup schedules
- S3/MinIO accessibility
- CronJobs

### `test_resources_pdb.py`
- Resource requests and limits
- CPU and memory validation
- Pod Disruption Budgets
- PDB configuration (maxUnavailable, minAvailable)

### `test_services.py`
- Service existence
- Service types
- Port configuration
- Selector validation
- Endpoints

## GitLab CI Integration

The `.gitlab-ci.yml` file is configured to run tests in GitLab CI/CD pipelines.

### Setup in GitLab

1. **Configure Kubernetes cluster access** in GitLab CI/CD variables:
   - `KUBECONFIG_DATA` (base64-encoded kubeconfig), OR
   - `KUBE_SERVER` and `KUBE_TOKEN` for token-based auth

2. **Configure AWS credentials** (for S3 backup tests):
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_REGION` (optional, defaults to us-east-1)
   - `PERCONA_BACKUP_BUCKET` (optional)

3. **Configure test parameters** (optional):
   - `TEST_NAMESPACE` (default: percona)
   - `TEST_CLUSTER_NAME` (default: pxc-cluster)
   - `TEST_EXPECTED_NODES` (default: 6)

### Running in GitLab CI

Tests will run automatically on:
- Push to `main` branch
- Merge requests

Manual jobs:
- `test:backup-s3` - Runs S3 backup validation (requires AWS credentials)

## Test Output

The test suite uses `rich` for beautiful console output:
- ✅ Green checkmarks for passing tests
- ❌ Red X marks for failing tests
- ⚠️ Yellow warnings for skipped tests
- 📊 Cyan informational messages

Example output:
```
test_cluster_versions.py::TestClusterVersions::test_kubernetes_version_compatibility PASSED
Kubernetes Version: 1.28
✓ Kubernetes version 1.28 is compatible

test_cluster_versions.py::TestClusterVersions::test_operator_version PASSED
Operator Image: percona/percona-xtradb-cluster-operator:1.14.0
```

## Troubleshooting

### Tests fail with "Cannot connect to Kubernetes cluster"

Ensure kubectl is configured:
```bash
kubectl cluster-info
kubectl get nodes
```

### Tests fail with "Namespace not found"

Create the namespace and deploy Percona cluster:
```bash
kubectl create namespace percona
# Deploy Percona cluster using your deployment method
```

### Tests fail with "No matching resources"

Verify the cluster name and namespace match:
```bash
kubectl get pxc -n percona
kubectl get statefulset -n percona
```

Set environment variables if different:
```bash
export TEST_NAMESPACE=my-namespace
export TEST_CLUSTER_NAME=my-cluster
```

### Import errors

Ensure all dependencies are installed:
```bash
pip install -r tests/requirements.txt
```

## Best Practices

1. **Run tests before deployment** to validate configuration
2. **Run tests after deployment** to verify everything is correctly configured
3. **Use in CI/CD pipelines** to catch configuration drift
4. **Run tests after cluster changes** to ensure nothing broke
5. **Review test output** for detailed validation information

## Contributing

When adding new tests:
1. Follow the existing test structure
2. Use descriptive test names
3. Add appropriate assertions with clear error messages
4. Use console.print() for informative output
5. Handle optional features gracefully (use pytest.skip() if needed)

## License

Same as the main project.


# On-Premise Test Suite

Comprehensive test suite for Percona XtraDB Cluster running on on-premise/VMware Kubernetes environments.

## Overview

This test suite is specifically designed for on-premise Kubernetes deployments (VMware, bare-metal, etc.). It supports:
- Fleet-based GitOps deployments with manifest rendering
- Hostname-based anti-affinity (no zone dependencies)
- Flexible storage class configuration
- Custom values file structures (e.g., `pxc-db:` wrappers)
- Schema normalization for different Helm chart layouts

## Quick Start

From this directory:

```bash
./run_tests.sh --on-prem
```

## Test Categories

- **Unit Tests**: Validate Helm values, templates, Fleet-rendered manifests
- **Integration Tests**: Verify deployed cluster state and configuration
- **Resiliency Tests**: Test chaos engineering and recovery scenarios
- **DR Scenario Tests**: Disaster recovery and failover testing

## Common Usage

### Run all tests (on-prem mode)
```bash
./run_tests.sh --on-prem
```

### Run with Fleet manifest rendering
```bash
export FLEET_YAML=./fleet.yaml
export FLEET_TARGET=k8s-dev
./run_tests.sh --on-prem
```

### Run only unit tests
```bash
./run_tests.sh --on-prem --no-integration-tests --no-resiliency-tests --no-dr-tests
```

### Run with verbose output
```bash
./run_tests.sh --on-prem --verbose
```

### Run specific test
```bash
./run_tests.sh --on-prem tests/unit/test_anti_affinity_rules.py::test_pxc_anti_affinity_required
```

### Run ProxySQL tests (instead of HAProxy)
```bash
./run_tests.sh --on-prem -- --proxysql
```

## On-Premise Configuration

This test suite assumes:
- **Storage Class**: Configurable (default: `standard`)
- **Topology Key**: `kubernetes.io/hostname` (node-based anti-affinity)
- **Single Datacenter**: No multi-AZ assumptions
- **Backup**: MinIO (S3-compatible)
- **Values File**: Fleet-rendered manifest or custom values file

## Fleet Integration

### Fleet Configuration Detection

When `--on-prem` is used and `fleet.yaml` exists, the test suite automatically:

1. **Parses `fleet.yaml`**: Extracts Helm chart URL and values files
2. **Renders Manifest**: Uses `helm template --insecure-skip-tls-verify` to generate Kubernetes manifests
3. **Extracts CR**: Finds the PerconaXtraDBCluster custom resource
4. **Tests Against CR**: All unit tests validate the rendered CR spec
5. **Redacts Secrets**: Secret data is automatically redacted in temp files
6. **Auto-cleanup**: Temporary rendered manifests are cleaned up after tests

### Example `fleet.yaml`

```yaml
helm:
  chart: https://my.registry.com/repository/helm-hosted/pxc.tgz
  releaseName: pxc-cluster
  
targetCustomizations:
  - name: k8s-dev
    helm:
      valuesFiles:
        - values/dev.yaml
    clusterSelector:
      matchLabels:
        env: dev
```

Set `FLEET_TARGET` to select which `targetCustomizations` entry to use:

```bash
export FLEET_TARGET=k8s-dev
./run_tests.sh --on-prem
```

## Environment Variables

### Required for On-Prem

```bash
ON_PREM=true                                # Enable on-prem mode
STORAGE_CLASS_NAME=standard                 # Your storage class name
TOPOLOGY_KEY=kubernetes.io/hostname         # Node-based anti-affinity
```

### Fleet Configuration

```bash
FLEET_YAML=./fleet.yaml                     # Path to fleet.yaml
FLEET_TARGET=k8s-dev                        # Target customization name
FLEET_RENDERED_MANIFEST=/tmp/manifest.yaml  # Auto-set by run_tests.sh
```

### Schema Normalization

For custom values file structures (e.g., nested under `pxc-db:`):

```bash
VALUES_FILE=./custom-values.yaml            # Path to values file
VALUES_ROOT_KEY=pxc-db                      # Root wrapper key
PXC_PATH=pxc-db.pxc                         # Dot-path to PXC section
PROXYSQL_PATH=pxc-db.proxysql               # Dot-path to ProxySQL
HAPROXY_PATH=pxc-db.haproxy                 # Dot-path to HAProxy
BACKUP_PATH=pxc-db.backup                   # Dot-path to backup config
```

### General Test Configuration

```bash
TEST_NAMESPACE=percona                      # Kubernetes namespace
TEST_CLUSTER_NAME=pxc-cluster               # Percona cluster name
TEST_EXPECTED_NODES=3                       # Expected PXC nodes
BACKUP_TYPE=minio                           # Backup type
BACKUP_BUCKET=percona-backups               # Backup bucket name
MINIO_NAMESPACE=minio                       # MinIO namespace
CHAOS_NAMESPACE=litmus                      # LitmusChaos namespace
```

## Prerequisites

- On-premise Kubernetes cluster
- Percona operator installed
- Python 3.11+ with venv
- kubectl configured for your cluster
- helm 3.x (for Fleet manifest rendering)
- (Optional) Fleet for GitOps deployments

## Test Structure

```
testing/on-prem/
├── run_tests.sh           # Main test runner (with --on-prem support)
├── conftest.py            # Pytest configuration (Fleet + schema normalization)
├── pytest.ini             # Pytest settings
├── requirements.txt       # Python dependencies
├── unit/                  # Unit tests (values, Fleet manifests, templates)
├── integration/           # Integration tests (deployed cluster)
├── resiliency/            # Resiliency and chaos tests
├── chaos-experiments/     # LitmusChaos experiments
├── disaster_scenarios/    # DR scenario definitions
├── scripts/               # Helper scripts
└── templates/             # Test resource manifests
```

## Key Tests

### Anti-Affinity Tests (On-Prem)
- Validate `affinity.antiAffinityTopologyKey: kubernetes.io/hostname`
- Ensure no zone-based assumptions
- Verify operator-managed anti-affinity rules

### Storage Tests (On-Prem)
- Validate custom StorageClass exists
- No AWS-specific provisioner checks
- Flexible storage parameters

### Fleet Manifest Tests
- Render Helm chart from Fleet configuration
- Extract PerconaXtraDBCluster CR
- Validate CR spec structure
- Test against actual deployed configuration

### Schema Normalization Tests
- Auto-detect component paths (pxc, proxysql, haproxy, backup)
- Handle wrapped structures (e.g., `pxc-db:` root key)
- Support environment variable path overrides

## Workflow Examples

### Test Against Fleet Deployment

```bash
# Set your Fleet configuration
export FLEET_YAML=./fleet.yaml
export FLEET_TARGET=k8s-prod

# Run tests against rendered manifest
./run_tests.sh --on-prem --verbose
```

### Test Custom Values File

```bash
# Point to your custom values
export VALUES_FILE=./my-custom-values.yaml
export VALUES_ROOT_KEY=pxc-db

# Run unit tests
./run_tests.sh --on-prem --no-integration-tests --no-resiliency-tests
```

### Test with Custom Storage Class

```bash
# Configure your storage class
export STORAGE_CLASS_NAME=ceph-rbd
export ON_PREM=true

# Run tests
./run_tests.sh --on-prem
```

## Notes

- This suite DOES use Fleet configurations and on-prem features
- For AWS EKS environments, use `../eks/` instead
- Tests handle both raw values files and Fleet-rendered manifests
- Schema normalization allows flexibility in values file structure
- Fleet manifest rendering requires `helm` and network access to chart registry

## Troubleshooting

### Fleet manifest rendering fails
Check helm can reach your chart registry:
```bash
helm template --insecure-skip-tls-verify my-release https://your.registry.com/chart.tgz
```

### Tests fail with topology key mismatch
Ensure `TOPOLOGY_KEY` is set correctly:
```bash
export TOPOLOGY_KEY=kubernetes.io/hostname
```

### Schema normalization errors
Check if your values file has a wrapper key:
```bash
export VALUES_ROOT_KEY=pxc-db
export PXC_PATH=pxc-db.pxc
```

### Tests expect wrong storage class
Override the storage class name:
```bash
export STORAGE_CLASS_NAME=your-storage-class
```

## Development

### Add new on-prem specific tests
1. Create test file in appropriate directory
2. Use `ON_PREM` environment variable to check mode
3. Handle both Fleet-rendered and raw values file sources
4. Use `get_values_for_test()` helper to load values

### Modify Fleet integration
Edit `run_tests.sh` (lines ~280-420) to customize Fleet parsing and rendering.

### Update schema normalization
Edit `conftest.py` `get_normalized_values()` function to handle new component structures.


# EKS Test Suite

Comprehensive test suite for Percona XtraDB Cluster running on AWS EKS.

## Overview

This test suite is specifically designed and optimized for AWS EKS environments. It validates:
- Multi-AZ deployment and zone-aware anti-affinity
- EKS-specific storage (gp3 StorageClass with EBS CSI driver)
- AWS-based backup strategies
- Kubernetes version compatibility
- Integration with AWS services

## Quick Start

From this directory:

```bash
./run_tests.sh
```

## Test Categories

- **Unit Tests**: Validate Helm values, templates, and configuration
- **Integration Tests**: Verify deployed cluster state and configuration
- **Resiliency Tests**: Test chaos engineering and recovery scenarios
- **DR Scenario Tests**: Disaster recovery and failover testing

## Common Usage

### Run all tests
```bash
./run_tests.sh
```

### Run only unit tests
```bash
./run_tests.sh --no-integration-tests --no-resiliency-tests --no-dr-tests
```

### Run with verbose output
```bash
./run_tests.sh --verbose
```

### Run specific test
```bash
./run_tests.sh tests/unit/test_percona_values_yaml.py::test_percona_values_pxc_configuration
```

### Run ProxySQL tests (instead of HAProxy)
```bash
./run_tests.sh -- --proxysql
```

## EKS-Specific Configuration

This test suite assumes:
- **Storage Class**: `gp3` (AWS EBS CSI driver)
- **Topology Key**: `topology.kubernetes.io/zone` (AZ-based anti-affinity)
- **Multi-AZ**: 3 availability zones (us-east-1a, us-east-1c, us-east-1d)
- **Backup**: MinIO or S3
- **Values File**: `percona/templates/percona-values.yaml`

## Environment Variables

```bash
TEST_NAMESPACE=percona                    # Kubernetes namespace
TEST_CLUSTER_NAME=pxc-cluster             # Percona cluster name
TEST_EXPECTED_NODES=3                     # Expected PXC nodes
BACKUP_TYPE=minio                         # Backup type: minio or s3
BACKUP_BUCKET=percona-backups             # Backup bucket name
STORAGE_CLASS_NAME=gp3                    # EKS storage class
TOPOLOGY_KEY=topology.kubernetes.io/zone  # AZ-based anti-affinity
MINIO_NAMESPACE=minio                     # MinIO namespace
CHAOS_NAMESPACE=litmus                    # LitmusChaos namespace
CHARTMUSEUM_NAMESPACE=chartmuseum         # ChartMuseum namespace
```

## Prerequisites

- AWS EKS cluster deployed (see `../../eks/README.md`)
- Percona operator installed (see `../../percona/README.md`)
- Python 3.11+ with venv
- kubectl configured for EKS cluster
- helm 3.x

## Test Structure

```
testing/eks/
├── run_tests.sh           # Main test runner
├── conftest.py            # Pytest configuration
├── pytest.ini             # Pytest settings
├── requirements.txt       # Python dependencies
├── unit/                  # Unit tests (Helm values, templates)
├── integration/           # Integration tests (deployed cluster)
├── resiliency/            # Resiliency and chaos tests
├── chaos-experiments/     # LitmusChaos experiments
├── disaster_scenarios/    # DR scenario definitions
├── scripts/               # Helper scripts
└── templates/             # Test resource manifests
```

## Key Tests

### Storage Tests
- Validate gp3 StorageClass exists
- Verify EBS CSI driver parameters
- Check PVC provisioning across AZs

### Anti-Affinity Tests
- Ensure zone-based topology keys
- Verify pods distributed across 3 AZs
- Validate label selectors

### Multi-AZ Tests
- Check node distribution across zones
- Verify PVC and pod zone alignment
- Test zone failure scenarios

## Notes

- This suite does NOT use Fleet configurations or on-prem features
- For on-premise/VMware environments, use `../on-prem/` instead
- Tests expect standard EKS networking and storage
- Chaos experiments require LitmusChaos operator

## Troubleshooting

### Tests fail with "gp3 StorageClass not found"
Ensure EBS CSI driver is installed:
```bash
kubectl get storageclass gp3
```

### Tests fail with zone distribution
Verify nodes are properly labeled:
```bash
kubectl get nodes --show-labels | grep topology.kubernetes.io/zone
```

### Port-forward issues
Check ChartMuseum is running:
```bash
kubectl get pods -n chartmuseum
```

## Development

### Add new tests
1. Create test file in appropriate directory (`unit/`, `integration/`, etc.)
2. Use pytest markers: `@pytest.mark.unit`, `@pytest.mark.integration`, etc.
3. Use fixtures from `conftest.py` (e.g., `values_norm`, `is_proxysql`)
4. Run specific test: `./run_tests.sh path/to/test.py::test_name`

### Modify test configuration
Edit `conftest.py` to add new fixtures or modify existing ones.

### Update values file path
Set `VALUES_FILE` environment variable to point to a different values file.


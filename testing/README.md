# Percona XtraDB Cluster Testing

This directory contains comprehensive tests for Percona XtraDB Cluster deployments in both on-prem and EKS environments.

## Test Structure

```
testing/
├── on-prem/              # On-premise deployment tests
│   ├── unit/             # Unit tests (manifest validation)
│   ├── integration/      # Integration tests (live cluster)
│   └── resiliency/       # Disaster recovery tests
├── eks/                  # EKS deployment tests
│   ├── unit/
│   ├── integration/
│   └── resiliency/
└── conftest.py           # Shared test configuration
```

## Test Categories

### Unit Tests
Validate configuration and manifest correctness before deployment. Run against rendered manifests.

- Image version validation (PXC, HAProxy, ProxySQL, Operator, XtraBackup)
- Resource configuration validation
- HA configuration validation
- Backup configuration validation
- Anti-affinity rules validation

### Integration Tests
Verify live cluster behavior and Kubernetes integration.

- Cluster deployment and status
- Pod distribution across zones
- PVC and storage configuration
- Service endpoints and selectors
- Backup workflow execution

### Resiliency Tests
Test disaster recovery scenarios and cluster recovery capabilities.

- Pod failure recovery
- Node failure recovery
- Service disruption recovery
- Quorum loss recovery
- Operator failure recovery

## Running Tests

### Prerequisites
```bash
pip install -r requirements.txt
```

### Environment Configuration
```bash
export TEST_NAMESPACE=percona
export TEST_CLUSTER_NAME=pxc-cluster
export FLEET_RENDERED_MANIFEST=/path/to/manifest.yaml
```

### Run All Tests
```bash
pytest -v
```

### Run Specific Test Category
```bash
pytest unit/ -v           # Unit tests only
pytest integration/ -v    # Integration tests only
pytest resiliency/ -v     # Resiliency tests only
```

### Run Specific Test
```bash
pytest unit/test_xtrabackup_version.py -v
```

## XtraBackup Version Test

The `test_xtrabackup_version.py` test validates that XtraBackup version is pinned to `8.4.0-4`.

### How It Works

1. **Loads Fleet-rendered manifest** - Contains all Kubernetes resources
2. **Finds PerconaXtraDBCluster resource** - Searches for `kind: PerconaXtraDBCluster`
3. **Extracts backup image** - Locates `spec.backup.image`:
   ```yaml
   spec:
     backup:
       image: percona/percona-xtradb-cluster-operator:8.4.0-4-pxc8.4-backup
   ```
4. **Parses version** - Uses regex to extract `8.4.0-4` from tag
5. **Validates** - Asserts version matches expected `8.4.0-4`

### What is XtraBackup?

Percona XtraBackup is the backup tool used for:
- **Hot backups** - Creates consistent backups while MySQL is running
- **State Snapshot Transfer (SST)** - Full data copy when nodes join the cluster
- **Point-in-Time Recovery (PITR)** - Works with binary logs for precise recovery
- **Incremental backups** - Saves storage and time

### Why Version Pinning Matters

- **Compatibility** - XtraBackup 8.4.0-4 is tested with PXC MySQL 8.4.x
- **Security** - Pinned versions prevent unexpected vulnerabilities
- **Compliance** - Demonstrates version control for audits (ISO, SOC2, SOX)
- **Reproducibility** - Guarantees backups use a known, validated tool

## Disaster Recovery Scenario Tests

Disaster recovery scenarios are defined in `disaster_scenarios.json` files and tested via:

1. **Detection** - Automated scenario detection scripts
2. **Recovery** - Step-by-step recovery procedures (markdown files in `dr-dashboard/`)
3. **Verification** - Resiliency tests that trigger and recover from failures

## Test Markers

Tests use pytest markers for categorization:

- `@pytest.mark.unit` - Unit tests (fast, no cluster required)
- `@pytest.mark.integration` - Integration tests (requires live cluster)
- `@pytest.mark.resiliency` - Resiliency tests (may cause disruption)

Run tests by marker:
```bash
pytest -m unit          # Unit tests only
pytest -m integration   # Integration tests only
pytest -m resiliency    # Resiliency tests only
```

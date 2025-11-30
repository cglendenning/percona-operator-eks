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
pytest unit/test_smart_update_strategy.py::test_update_strategy_is_smart_update -v
pytest unit/test_smart_update_strategy.py::test_upgrade_options_apply_is_disabled -v
```

## Critical Unit Tests

### XtraBackup Version Test

The `test_xtrabackup_version.py` test validates that XtraBackup version is pinned to `8.4.0-4`.

**How it works:**
1. Loads Fleet-rendered manifest
2. Finds PerconaXtraDBCluster resource
3. Extracts `spec.backup.image`
4. Validates version is `8.4.0-4`

**What is XtraBackup?**
Percona XtraBackup is the backup tool used for hot backups, State Snapshot Transfer (SST), Point-in-Time Recovery (PITR), and incremental backups.

**Why it matters:**
- Compatibility with PXC MySQL 8.4.x
- Security through version pinning
- Compliance for audits
- Reproducible backups

### SmartUpdate Strategy Test

The `test_smart_update_strategy.py` test validates that the PerconaXtraDBCluster updateStrategy is set to `SmartUpdate`.

**How it works:**
1. Loads Fleet-rendered manifest
2. Finds PerconaXtraDBCluster resource
3. Extracts `spec.updateStrategy`
4. Validates it is set to `SmartUpdate`

**What is SmartUpdate?**
SmartUpdate is the Percona Operator's intelligent rolling update strategy that:
- Maintains cluster quorum during updates
- Waits for Galera sync status before proceeding
- Minimizes risk of data loss or downtime
- Automatically handles node failures during updates

**Valid updateStrategy values:**
- `SmartUpdate` (recommended) - Operator-managed intelligent updates
- `RollingUpdate` - Standard Kubernetes rolling update
- `OnDelete` - Manual update control

**Why it matters:**
- Ensures zero-downtime updates
- Prevents quorum loss during rolling updates
- Guarantees data consistency during operator upgrades
- Production best practice for PXC clusters

### Upgrade Options Test

The `test_smart_update_strategy.py` test also validates that `upgradeOptions.apply` is set to `disabled`.

**How it works:**
1. Loads Fleet-rendered manifest
2. Finds PerconaXtraDBCluster resource
3. Extracts `spec.upgradeOptions.apply`
4. Validates it is set to `disabled`

**What is upgradeOptions.apply?**
Controls automatic version upgrades of PXC components:
- `disabled` (recommended for production) - Manual upgrade control
- `recommended` - Auto-apply recommended version updates
- `latest` - Auto-apply latest version (not recommended)
- `X.Y.Z` - Auto-upgrade to specific version

**Why disabled matters:**
- Prevents unexpected automatic upgrades
- Ensures change management process is followed
- Allows validation in lower environments first
- Maintains version consistency across clusters
- Prevents potential downtime from automatic upgrades
- Critical for production stability and compliance

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

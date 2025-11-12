# Percona XtraDB Cluster Deployment

This directory contains deployment scripts and configurations for Percona XtraDB Cluster on Kubernetes, organized by environment type.

## Directory Structure

```
percona/
├── eks/                    # EKS-specific deployment
│   ├── install.sh         # Installation script for AWS EKS
│   ├── templates/         # EKS-specific templates
│   └── README.md          # EKS documentation
├── on-prem/               # On-premise deployment
│   ├── install.sh         # Installation script for vSphere/vCenter
│   ├── templates/         # On-prem-specific templates
│   └── README.md          # On-prem documentation
├── scripts/               # Shared utility scripts
│   ├── monitoring/        # Load testing monitoring tools
│   ├── install-litmus.sh # Chaos engineering setup
│   └── ...
├── src/                   # TypeScript automation (legacy)
├── templates/             # Shared templates
└── README.md              # This file
```

## Quick Start

### For AWS EKS

```bash
cd percona/eks
./install.sh
```

**Features:**
- Percona XtraDB Cluster 8.4.6
- HAProxy 2.8.15
- Multi-AZ deployment (3 availability zones)
- EBS gp3 storage
- Automatic resource calculation

[Full EKS Documentation →](eks/README.md)

### For On-Premise (vSphere/vCenter)

```bash
cd percona/on-prem
./install.sh
```

**Features:**
- Percona XtraDB Cluster 8.4.6
- HAProxy 2.8.15
- Host-based anti-affinity
- vSphere storage integration
- Automatic resource calculation

[Full On-Prem Documentation →](on-prem/README.md)

## Installation Features

Both installers provide:

✅ **Interactive Configuration**
   - Prompts for data directory size
   - Prompts for max memory per node
   - Automatic InnoDB buffer pool calculation (70% of memory)

✅ **Version Control**
   - XtraDB 8.4.6 (MySQL 8.4 compatible)
   - HAProxy 2.8.15 (latest stable)
   - Percona Operator 1.15.0

✅ **Safety**
   - Namespace isolation (all components in single namespace)
   - No impact on other namespaces or workloads
   - Confirmation before installation

✅ **Cross-Platform**
   - Works on macOS
   - Works on WSL/Linux
   - Minimal dependencies (kubectl, helm, bc)

✅ **Production-Ready**
   - High availability (3-node cluster)
   - Automatic backups with PITR
   - Pod disruption budgets
   - Anti-affinity rules

## Component Versions

| Component | Version | Purpose |
|-----------|---------|---------|
| **Percona XtraDB Cluster** | 8.4.6 | MySQL-compatible database with Galera replication |
| **HAProxy** | 2.8.15 | Load balancer and connection pooler |
| **Percona Operator** | 1.15.0 | Kubernetes operator for lifecycle management |
| **MinIO** | Latest | S3-compatible backup storage |

## Configuration Comparison

| Feature | EKS | On-Premise |
|---------|-----|------------|
| **Storage Class** | `gp3` (EBS) | User-specified (vSphere) |
| **Anti-Affinity** | `topology.kubernetes.io/zone` | `kubernetes.io/hostname` |
| **Distribution** | Across 3 AZs | Across different hosts |
| **Backup Storage** | AWS S3 (native) | MinIO (S3-compatible) |
| **Backup Schedule** | Daily full @ 2am UTC + PITR | Daily full @ 2am UTC + PITR |
| **Load Balancer** | HAProxy (3 replicas) | HAProxy (3 replicas) |
| **Operator Scope** | Namespace-scoped | Namespace-scoped |

## Prerequisites

### All Environments

- Kubernetes 1.24+ cluster
- `kubectl` configured and connected
- `helm` 3.x installed
- `bc` command (for calculations)
- At least 3 worker nodes for HA

### EKS-Specific

- EKS cluster with EBS CSI driver
- gp3 storage class configured

### On-Prem-Specific

- vSphere/vCenter with Kubernetes integration
- StorageClass configured (vSAN, thin, thick, etc.)
- vSphere cloud provider or CSI driver

## Post-Installation

### Check Cluster Status

```bash
# View all resources
kubectl get all -n percona

# Check PXC custom resource
kubectl get pxc -n percona

# View pod distribution
kubectl get pods -n percona -o wide
```

### Connect to MySQL

```bash
# Get root password
ROOT_PASS=$(kubectl get secret pxc-cluster-secrets -n percona \
  -o jsonpath='{.data.root}' | base64 -d)

# Connect via HAProxy (recommended)
kubectl exec -it pxc-cluster-pxc-0 -n percona -- \
  mysql -h pxc-cluster-haproxy -uroot -p"$ROOT_PASS"

# Connect directly to a node
kubectl exec -it pxc-cluster-pxc-0 -n percona -- \
  mysql -uroot -p"$ROOT_PASS"
```

### Monitor Performance

```bash
# Use load testing monitoring tools
cd scripts/monitoring
./monitor-pxc-load-test.sh -h pxc-cluster-haproxy.percona.svc.cluster.local \
  -u root -p"$ROOT_PASS"
```

## Load Testing

For load testing and performance monitoring, see:
- [Load Testing Monitoring Tools](scripts/monitoring/README.md)
- [PXC Load Test Queries](scripts/monitoring/pxc-load-test-queries.sql)

## Backup & Recovery

### Scheduled Backups

Both EKS and on-premise configurations include:
- **Daily Full Backup**: 2:00 AM UTC, retained for 7 days
- **PITR (Point-in-Time Recovery)**: Binary logs uploaded every 60 seconds

### Storage Differences

- **EKS**: Uses native AWS S3 bucket `percona-backups-<namespace>`
- **On-Prem**: Uses MinIO S3-compatible storage (requires separate MinIO deployment)

### Manual Backup

**EKS:**
```bash
kubectl apply -f - <<EOF
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterBackup
metadata:
  name: manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: percona
spec:
  pxcCluster: pxc-cluster
  storageName: s3
EOF
```

**On-Prem:**
```bash
kubectl apply -f - <<EOF
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterBackup
metadata:
  name: manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: percona
spec:
  pxcCluster: pxc-cluster
  storageName: minio
EOF
```

### Point-in-Time Recovery (PITR)

PITR is enabled by default with binary logs uploaded every 60 seconds.

```bash
# Restore to specific timestamp
kubectl apply -f - <<EOF
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterRestore
metadata:
  name: restore-to-timestamp
  namespace: percona
spec:
  pxcCluster: pxc-cluster
  backupName: daily-backup-20250112
  pitr:
    type: date
    date: "2025-01-12 10:30:00"
EOF
```

## Uninstallation

### Remove Cluster (Keep Data)

```bash
# Delete cluster, keep PVCs
helm uninstall pxc-cluster -n percona

# Delete operator
helm uninstall percona-operator -n percona
```

### Complete Removal (Delete All Data)

```bash
# Delete cluster
helm uninstall pxc-cluster -n percona

# Delete operator
helm uninstall percona-operator -n percona

# Delete all PVCs (⚠️ DELETES ALL DATA)
kubectl delete pvc -n percona --all

# Delete namespace
kubectl delete namespace percona
```

## Troubleshooting

### Common Issues

1. **Pods stuck in Pending**
   - Check storage class exists
   - Verify PVC can be created
   - Check node resources

2. **Pods not ready**
   - Check pod logs: `kubectl logs pxc-cluster-pxc-0 -n percona`
   - Check events: `kubectl get events -n percona`
   - Verify operator is running

3. **Connection refused**
   - Check HAProxy service: `kubectl get svc pxc-cluster-haproxy -n percona`
   - Verify pods are ready: `kubectl get pods -n percona`
   - Test DNS: `nslookup pxc-cluster-haproxy.percona.svc.cluster.local`

### Get Support

```bash
# Collect diagnostics
kubectl get all -n percona -o yaml > percona-diagnostics.yaml
kubectl get pxc -n percona -o yaml >> percona-diagnostics.yaml
kubectl get events -n percona >> percona-diagnostics.yaml
kubectl logs -n percona -l app.kubernetes.io/name=percona-xtradb-cluster-operator \
  >> percona-diagnostics.yaml
```

## Migration Guide

### From TypeScript/Node.js to Shell Scripts

The previous TypeScript-based deployment (`npm run percona`) has been replaced with environment-specific shell scripts for better clarity and maintainability.

**Old approach:**
```bash
npm run percona -- install --namespace percona --nodes 3
```

**New approach:**
```bash
# For EKS
./percona/eks/install.sh

# For On-Prem
./percona/on-prem/install.sh
```

The TypeScript sources remain in `src/` for reference and potential future automation needs.

## Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                       │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │               Namespace: percona                      │  │
│  │                                                       │  │
│  │  Percona Operator (watches namespace)                │  │
│  │  │                                                    │  │
│  │  ├─→ PXC Cluster (StatefulSet, 3 nodes)             │  │
│  │  │   ├─ pxc-0 [100Gi PV, 16Gi RAM]                  │  │
│  │  │   ├─ pxc-1 [100Gi PV, 16Gi RAM]                  │  │
│  │  │   └─ pxc-2 [100Gi PV, 16Gi RAM]                  │  │
│  │  │                                                    │  │
│  │  ├─→ HAProxy (StatefulSet, 3 nodes)                 │  │
│  │  │   ├─ haproxy-0 [Load Balancer]                   │  │
│  │  │   ├─ haproxy-1 [Load Balancer]                   │  │
│  │  │   └─ haproxy-2 [Load Balancer]                   │  │
│  │  │                                                    │  │
│  │  └─→ Backup CronJobs                                 │  │
│  │      ├─ daily-backup                                 │  │
│  │      └─ weekly-backup                                │  │
│  │                                                       │  │
│  │  Service: pxc-cluster-haproxy:3306 (entry point)    │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## See Also

- [Percona Operator Documentation](https://docs.percona.com/percona-operator-for-mysql/pxc/)
- [Percona XtraDB Cluster Documentation](https://docs.percona.com/percona-xtradb-cluster/8.0/)
- [HAProxy Documentation](https://www.haproxy.org/documentation/)
- [MySQL 8.4 Reference Manual](https://dev.mysql.com/doc/refman/8.4/en/)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)

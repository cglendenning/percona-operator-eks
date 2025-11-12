# Percona XtraDB Cluster for EKS

This directory contains the installation script and configuration for deploying Percona XtraDB Cluster on Amazon EKS.

## Features

- ✅ **Percona XtraDB Cluster 8.4.6** - Latest stable MySQL-compatible database
- ✅ **HAProxy 2.8.15** - High-performance load balancer and connection pooler
- ✅ **Percona Operator 1.15.0** - Kubernetes operator for lifecycle management
- ✅ **Multi-AZ deployment** - Pods spread across availability zones
- ✅ **Automatic backups** - MinIO S3-compatible storage with PITR
- ✅ **Configurable resources** - Custom memory and storage per node
- ✅ **InnoDB tuning** - Buffer pool set to 70% of allocated memory
- ✅ **Namespace isolation** - All components in single namespace

## Prerequisites

- EKS cluster running and accessible via `kubectl`
- `kubectl` CLI tool installed
- `helm` 3.x installed
- `bc` installed (for calculations)
- EBS CSI driver configured (for gp3 volumes)

## Quick Start

```bash
./percona/eks/install.sh
```

The script will interactively prompt you for:
1. Data directory size per node (e.g., 50Gi, 100Gi)
2. Maximum memory per node (e.g., 4Gi, 8Gi, 16Gi)
3. Confirmation before proceeding

### Example Installation

```bash
$ ./percona/eks/install.sh

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Percona XtraDB Cluster Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Enter namespace name [default: percona]: prod-mysql

This script will install:
  - Percona XtraDB Cluster 8.4.6-2
  - HAProxy 2.8.15
  - Percona Operator 1.15.0
  - All components in namespace: prod-mysql

Enter data directory size per node (e.g., 50Gi, 100Gi) [default: 50Gi]: 100Gi
Enter max memory per node (e.g., 4Gi, 8Gi, 16Gi) [default: 8Gi]: 16Gi

[INFO] Configuration Summary:
  - Namespace: prod-mysql
  - Cluster Name: pxc-cluster
  - Nodes: 3
  - Data Directory Size: 100Gi
  - Max Memory per Node: 16Gi
  - InnoDB Buffer Pool Size (70%): 11468M
  - Storage Class: gp3
  - PXC Version: 8.4.6-2
  - HAProxy Version: 2.8.15

Proceed with installation? (yes/no): yes
```

## Configuration

### Environment Variables

You can customize the installation by setting environment variables (or use interactive prompts):

```bash
# Custom namespace (or will be prompted)
NAMESPACE=my-percona ./percona/eks/install.sh

# Custom cluster name
CLUSTER_NAME=my-cluster ./percona/eks/install.sh

# Different number of nodes
PXC_NODES=5 ./percona/eks/install.sh
```

**Note**: If `NAMESPACE` is not set as an environment variable, the script will prompt you for it interactively.

### Resource Calculations

The script automatically calculates optimal settings:
- **InnoDB Buffer Pool**: Set to 70% of max memory
- **Memory Requests**: Set to 80% of max memory
- **Memory Limits**: Set to max memory specified
- **CPU**: 1 CPU request, 2 CPU limit per node

### Storage

- **Storage Class**: `gp3` (EBS volumes optimized for cost/performance)
- **Volume Size**: Custom per installation
- **Access Mode**: ReadWriteOnce
- **Backup Storage**: AWS S3 (native)

### Multi-AZ Distribution

Pods are automatically distributed across availability zones using:
- **Anti-affinity rules**: `topology.kubernetes.io/zone`
- **Pod Disruption Budget**: maxUnavailable = 1
- **3 nodes minimum**: One per AZ in us-east-1a, us-east-1c, us-east-1d

## What Gets Installed

In the specified namespace (default: `percona`):

1. **Percona Operator**
   - Deployment: `percona-xtradb-cluster-operator`
   - Manages PXC lifecycle

2. **PXC Cluster**
   - StatefulSet: `pxc-cluster-pxc` (3 pods)
   - Service: `pxc-cluster-pxc` (headless)
   - Secrets: `pxc-cluster-secrets` (root password, etc.)

3. **HAProxy**
   - StatefulSet: `pxc-cluster-haproxy` (3 pods)
   - Service: `pxc-cluster-haproxy` (load balancer)

4. **Backup Storage**
   - Secret: `percona-backup-s3` (AWS credentials)
   - S3 bucket: `percona-backups-<namespace>`
   - CronJobs for scheduled backups
   - PITR enabled with binary log uploads every 60 seconds

## Post-Installation

### Connect to MySQL

```bash
# Get root password
kubectl get secret pxc-cluster-secrets -n percona \
  -o jsonpath='{.data.root}' | base64 -d

# Connect via HAProxy
kubectl exec -it pxc-cluster-pxc-0 -n percona -- \
  mysql -h pxc-cluster-haproxy -uroot -p

# Connect directly to node
kubectl exec -it pxc-cluster-pxc-0 -n percona -- \
  mysql -uroot -p
```

### Monitor Cluster

```bash
# Check cluster status
kubectl get pxc -n percona

# View all pods
kubectl get pods -n percona -o wide

# Check services
kubectl get svc -n percona

# View operator logs
kubectl logs -n percona -l app.kubernetes.io/name=percona-xtradb-cluster-operator

# View PXC node logs
kubectl logs -n percona pxc-cluster-pxc-0
```

### Backup Management

**Automated Backups:**
- **Daily Full Backup**: 2:00 AM UTC, retained for 7 days
- **PITR (Point-in-Time Recovery)**: Binary logs uploaded every 60 seconds
- **Storage**: AWS S3 bucket `percona-backups-<namespace>`

```bash
# List backups
kubectl get pxc-backup -n percona

# View backup schedule
kubectl get pxc pxc-cluster -n percona -o yaml | grep -A 20 "schedule:"

# Create manual backup
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

# Check backup status
kubectl describe pxc-backup manual-backup-TIMESTAMP -n percona

# View S3 backups (requires AWS CLI)
aws s3 ls s3://percona-backups-percona/ --recursive
```

### Load Testing

Use the monitoring tools to observe cluster behavior under load:

```bash
# Run monitoring during load testing
cd ../../monitoring
./monitor-pxc-load-test.sh -h pxc-cluster-haproxy.percona.svc.cluster.local -u root -p
```

## Troubleshooting

### Pods not starting

```bash
# Check pod status
kubectl describe pod pxc-cluster-pxc-0 -n percona

# Check events
kubectl get events -n percona --sort-by='.lastTimestamp'

# Check PVC status
kubectl get pvc -n percona
```

### Storage issues

```bash
# Verify storage class exists
kubectl get storageclass gp3

# Check EBS CSI driver
kubectl get pods -n kube-system -l app=ebs-csi-controller
```

### Connection issues

```bash
# Test DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nslookup pxc-cluster-haproxy.percona.svc.cluster.local

# Check HAProxy health
kubectl exec -it pxc-cluster-haproxy-0 -n percona -- curl localhost:8404
```

## Uninstallation

### Safe Uninstall Script (Recommended)

Use the interactive uninstall script that prompts for confirmation and shows exactly what will be deleted:

```bash
./percona/eks/uninstall.sh
```

The script will:
1. ✅ Prompt for the namespace to uninstall
2. ✅ Show all resources that will be deleted (Helm releases, pods, PVCs, PVs)
3. ✅ Ask for confirmation before proceeding
4. ✅ Optionally preserve PVCs and data
5. ✅ Optionally preserve the namespace

**Example uninstall session:**
```bash
$ ./percona/eks/uninstall.sh

Enter namespace to uninstall from: percona

[Shows all resources: Helm releases, PXC clusters, pods, PVCs, PVs, secrets...]

Are you sure you want to proceed? (type 'yes' to confirm): yes
Do you want to delete PVCs and PVs? (yes/no) [no]: yes

⚠️  WARNING: Deleting PVCs will permanently delete all database data!
⚠️  This action CANNOT be undone!

Type 'DELETE ALL DATA' to confirm PVC deletion: DELETE ALL DATA

Do you want to delete the namespace 'percona'? (yes/no) [no]: yes
```

### Manual Uninstallation

If you prefer manual uninstallation:

```bash
# Delete cluster
helm uninstall pxc-cluster -n percona

# Delete operator
helm uninstall percona-operator -n percona

# Delete PVCs (⚠️ will delete all data!)
kubectl delete pvc -n percona --all

# Delete namespace
kubectl delete namespace percona
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         EKS Cluster                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                   Namespace: percona                  │  │
│  │                                                       │  │
│  │  ┌─────────────────────────────────────────────┐     │  │
│  │  │         Percona Operator (Deployment)       │     │  │
│  │  └─────────────────────────────────────────────┘     │  │
│  │                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │   PXC-0     │  │   PXC-1     │  │   PXC-2     │  │  │
│  │  │  (us-e-1a)  │  │  (us-e-1c)  │  │  (us-e-1d)  │  │  │
│  │  │  100Gi gp3  │  │  100Gi gp3  │  │  100Gi gp3  │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  │                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │  HAProxy-0  │  │  HAProxy-1  │  │  HAProxy-2  │  │  │
│  │  │  (us-e-1a)  │  │  (us-e-1c)  │  │  (us-e-1d)  │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  │                                                       │  │
│  │  Service: pxc-cluster-haproxy:3306                   │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## See Also

- [Percona Operator Documentation](https://docs.percona.com/percona-operator-for-mysql/pxc/)
- [HAProxy Configuration](https://www.haproxy.org/documentation/)
- [MySQL 8.4 Reference](https://dev.mysql.com/doc/refman/8.4/en/)
- [Load Testing Guide](../../monitoring/README.md)


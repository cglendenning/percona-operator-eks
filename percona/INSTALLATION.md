# Percona XtraDB Cluster Installation Guide

## Overview

This guide walks you through installing Percona XtraDB Cluster 8.4.6 with HAProxy 2.8.15 on either EKS or on-premise Kubernetes.

## Quick Reference

| Specification | Value |
|---------------|-------|
| **PXC Version** | 8.4.6-2 (MySQL 8.4 compatible) |
| **HAProxy Version** | 2.8.15 |
| **Operator Version** | 1.15.0 |
| **Proxy** | HAProxy (ProxySQL disabled) |
| **Buffer Pool** | 70% of max memory (auto-calculated) |
| **Namespace** | Single namespace (default: `percona`) |
| **HA Configuration** | 3 nodes with anti-affinity |

## Installation Steps

### Step 1: Choose Your Environment

#### For AWS EKS

Navigate to the EKS directory and run the installer:

```bash
cd percona/eks
./install.sh
```

#### For On-Premise vSphere/vCenter

Navigate to the on-prem directory and run the installer:

```bash
cd percona/on-prem
./install.sh
```

### Step 2: Answer Configuration Prompts

Both installers will prompt you for:

1. **Namespace Name**
   - Default: `percona`
   - Example: `prod-db`, `mysql-cluster`, `pxc-dev`
   - All components will be installed in this namespace

2. **Storage Size** (EKS only uses gp3, on-prem prompts for StorageClass first)
   - Example: `50Gi`, `100Gi`, `250Gi`
   - This is the persistent volume size for each PXC node's data directory

3. **Maximum Memory per Node**
   - Example: `4Gi`, `8Gi`, `16Gi`, `32Gi`
   - This sets the memory limit for each PXC pod
   - InnoDB buffer pool will be automatically set to 70% of this value

4. **Confirmation**
   - Review the configuration summary
   - Type `yes` to proceed with installation

### Step 3: Wait for Installation

The installer will:

1. ✅ Check prerequisites (kubectl, helm, bc)
2. ✅ Create namespace
3. ✅ Install Percona Operator
4. ✅ Wait for operator to be ready
5. ✅ Create MinIO backup credentials
6. ✅ Generate Helm values
7. ✅ Install PXC cluster
8. ✅ Wait for all pods to be ready
9. ✅ Display connection information

**Expected time:** 5-15 minutes depending on cluster performance

### Step 4: Verify Installation

After installation completes, verify the cluster:

```bash
# Check all pods are running
kubectl get pods -n percona

# Expected output:
# NAME                                        READY   STATUS    RESTARTS   AGE
# percona-xtradb-cluster-operator-xxx-yyy    1/1     Running   0          5m
# pxc-cluster-pxc-0                          1/1     Running   0          3m
# pxc-cluster-pxc-1                          1/1     Running   0          2m
# pxc-cluster-pxc-2                          1/1     Running   0          1m
# pxc-cluster-haproxy-0                      2/2     Running   0          3m
# pxc-cluster-haproxy-1                      2/2     Running   0          2m
# pxc-cluster-haproxy-2                      2/2     Running   0          1m

# Check PXC custom resource
kubectl get pxc -n percona

# Check services
kubectl get svc -n percona
```

### Step 5: Connect to the Cluster

The installer displays the root password at the end. Save it!

```bash
# Get root password (if you missed it)
kubectl get secret pxc-cluster-secrets -n percona \
  -o jsonpath='{.data.root}' | base64 -d && echo

# Connect via HAProxy (recommended for load balancing)
kubectl exec -it pxc-cluster-pxc-0 -n percona -- \
  mysql -h pxc-cluster-haproxy -uroot -p

# Or connect directly to a node
kubectl exec -it pxc-cluster-pxc-0 -n percona -- \
  mysql -uroot -p
```

## Configuration Details

### InnoDB Buffer Pool Calculation

The installer automatically calculates `innodb_buffer_pool_size` as **70% of max memory**:

| Max Memory | Buffer Pool Size | Rationale |
|------------|------------------|-----------|
| 4Gi | 2867M | Leaves 1.3Gi for OS, connections, temp tables |
| 8Gi | 5734M | Leaves 2.6Gi for OS, connections, temp tables |
| 16Gi | 11468M | Leaves 5.2Gi for OS, connections, temp tables |
| 32Gi | 22937M | Leaves 10.3Gi for OS, connections, temp tables |

### Resource Allocation

For each PXC node:

```yaml
resources:
  requests:
    memory: 80% of max_memory  # For scheduling
    cpu: 1
  limits:
    memory: max_memory         # Hard limit
    cpu: 2
```

For each HAProxy node:

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 200m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Anti-Affinity Rules

**EKS:** Pods spread across availability zones

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: topology.kubernetes.io/zone
```

**On-Prem:** Pods spread across different hosts

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
```

## Safety Features

### Namespace Isolation

✅ **All components installed in single namespace**
- Default: `percona`
- Customizable: `NAMESPACE=my-percona ./install.sh`

✅ **No impact on other namespaces**
- Operator watches only its own namespace (`watchNamespace`)
- Resources labeled for easy identification
- PVCs tied to namespace

✅ **Clean separation from other workloads**
- No cluster-wide CRDs conflicts
- No cross-namespace access
- Easy to uninstall completely

### Confirmation Required

The installer requires explicit `yes` confirmation:
- Reviews all configuration before proceeding
- Shows calculated values (buffer pool size)
- Displays namespace and cluster name
- No accidental installations

## Troubleshooting

### Prerequisites Missing

```bash
# Install kubectl (macOS)
brew install kubectl

# Install helm (macOS)
brew install helm

# Install bc (macOS)
brew install bc

# Install kubectl (Ubuntu/WSL)
sudo apt-get update && sudo apt-get install -y kubectl

# Install helm (Ubuntu/WSL)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install bc (Ubuntu/WSL)
sudo apt-get install -y bc
```

### Cannot Connect to Cluster

```bash
# Verify kubectl is configured
kubectl cluster-info

# Check current context
kubectl config current-context

# List available contexts
kubectl config get-contexts
```

### Installation Fails

```bash
# Check operator logs
kubectl logs -n percona -l app.kubernetes.io/name=percona-xtradb-cluster-operator

# Check pod events
kubectl get events -n percona --sort-by='.lastTimestamp'

# Describe stuck pod
kubectl describe pod <pod-name> -n percona

# Check PVC status
kubectl get pvc -n percona
```

### Pods Stuck in Pending

**Check storage:**
```bash
# Verify storage class exists (EKS)
kubectl get storageclass gp3

# Verify storage class exists (on-prem)
kubectl get storageclass

# Check PVC status
kubectl describe pvc datadir-pxc-cluster-pxc-0 -n percona
```

**Check resources:**
```bash
# Check node resources
kubectl top nodes

# Check if nodes can fit the pods
kubectl describe nodes | grep -A 5 "Allocated resources"
```

## Advanced Usage

### Custom Namespace

You can either set it as an environment variable or let the script prompt you:

**Via environment variable:**
```bash
NAMESPACE=production-db ./percona/eks/install.sh
```

**Via interactive prompt (default):**
```bash
./percona/eks/install.sh
# You'll be prompted: Enter namespace name [default: percona]:
```

### Custom Cluster Name

```bash
CLUSTER_NAME=prod-mysql ./percona/eks/install.sh
```

### Different Number of Nodes

```bash
PXC_NODES=5 ./percona/eks/install.sh
```

### Combine Multiple Variables

```bash
NAMESPACE=prod-db CLUSTER_NAME=mysql-main PXC_NODES=5 \
  ./percona/eks/install.sh
```

## Backup Configuration

Backups are automatically configured for both environments:

### Scheduled Backups

- **Daily Full Backup:** 2:00 AM UTC, retained for 7 days
- **PITR (Point-in-Time Recovery):** Binary logs uploaded every 60 seconds

### Storage Configuration

**EKS:**
- Uses native AWS S3
- Bucket: `percona-backups-<namespace>`
- Credentials: AWS Access Key + Secret Key (from environment, AWS CLI config, or prompted)

**On-Premise:**
- Uses MinIO S3-compatible storage
- Endpoint: `http://minio.minio.svc.cluster.local:9000`
- Credentials: Auto-generated during installation
- **Note**: MinIO must be deployed separately in the `minio` namespace

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

### Installing MinIO (On-Prem Only)

MinIO must be installed before running the on-prem installer:

```bash
helm repo add minio https://charts.min.io/
helm install minio minio/minio \
  --namespace minio --create-namespace \
  --set persistence.size=100Gi \
  --set mode=standalone
```

## Uninstallation

### Keep Data (Safe)

```bash
# Delete cluster
helm uninstall pxc-cluster -n percona

# Delete operator
helm uninstall percona-operator -n percona

# PVCs remain - data is safe
```

### Complete Removal (⚠️ Deletes All Data)

```bash
# Delete cluster
helm uninstall pxc-cluster -n percona

# Delete operator
helm uninstall percona-operator -n percona

# Delete PVCs (⚠️ DELETES ALL DATA!)
kubectl delete pvc -n percona --all

# Delete namespace
kubectl delete namespace percona
```

## Next Steps

After installation:

1. **Create users and databases**
   ```sql
   CREATE DATABASE myapp;
   CREATE USER 'myapp'@'%' IDENTIFIED BY 'secure_password';
   GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'%';
   FLUSH PRIVILEGES;
   ```

2. **Configure application**
   - Use HAProxy service: `pxc-cluster-haproxy.percona.svc.cluster.local:3306`
   - Connection pooling handled by HAProxy
   - Automatic failover on node failure

3. **Set up monitoring**
   - Use load testing tools in `monitoring/` directory
   - Monitor Galera cluster status
   - Watch for flow control events

4. **Test backups**
   - Verify automated backups are working
   - Test restore procedure
   - Validate PITR functionality

5. **Load testing**
   ```bash
   cd ../../monitoring
   ./monitor-pxc-load-test.sh -h pxc-cluster-haproxy.percona.svc.cluster.local -u root -p
   ```

## Support

For issues or questions:

1. Check the environment-specific README:
   - [EKS README](eks/README.md)
   - [On-Prem README](on-prem/README.md)

2. Review Percona documentation:
   - [Percona Operator](https://docs.percona.com/percona-operator-for-mysql/pxc/)
   - [Percona XtraDB Cluster](https://docs.percona.com/percona-xtradb-cluster/8.0/)

3. Collect diagnostics:
   ```bash
   kubectl get all -n percona -o yaml > diagnostics.yaml
   kubectl get events -n percona >> diagnostics.yaml
   kubectl logs -n percona -l app.kubernetes.io/name=percona-xtradb-cluster-operator >> diagnostics.yaml
   ```
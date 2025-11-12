# Percona XtraDB Cluster for On-Premise (vSphere/vCenter)

This directory contains the installation script and configuration for deploying Percona XtraDB Cluster on on-premise Kubernetes clusters running on vSphere/vCenter.

## Features

- ✅ **Percona XtraDB Cluster 8.4.6** - Latest stable MySQL-compatible database
- ✅ **HAProxy 2.8.15** - High-performance load balancer and connection pooler
- ✅ **Percona Operator 1.15.0** - Kubernetes operator for lifecycle management
- ✅ **Host-based anti-affinity** - Pods spread across different nodes
- ✅ **Automatic backups** - MinIO S3-compatible storage with PITR
- ✅ **Configurable resources** - Custom memory and storage per node
- ✅ **InnoDB tuning** - Buffer pool set to 70% of allocated memory
- ✅ **Namespace isolation** - All components in single namespace
- ✅ **vSphere integration** - Compatible with vCenter storage classes

## Prerequisites

- Kubernetes cluster on vSphere/vCenter
- `kubectl` CLI tool configured and connected
- `helm` 3.x installed
- `bc` installed (for calculations)
- StorageClass configured in your cluster
- At least 3 worker nodes for HA deployment

## Quick Start

```bash
./percona/on-prem/install.sh
```

The script will interactively prompt you for:
1. StorageClass name (from your vSphere configuration)
2. Data directory size per node (e.g., 50Gi, 100Gi)
3. Maximum memory per node (e.g., 4Gi, 8Gi, 16Gi)
4. Confirmation before proceeding

### Example Installation

```bash
$ ./percona/on-prem/install.sh

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Percona XtraDB Cluster Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Enter namespace name [default: percona]: mysql-prod

This script will install:
  - Percona XtraDB Cluster 8.4.6-2
  - HAProxy 2.8.15
  - Percona Operator 1.15.0
  - All components in namespace: mysql-prod
  - Environment: On-Premise vSphere/vCenter

[INFO] Available StorageClasses in cluster:
  - vsphere-standard
  - vsphere-thin
  - vsphere-thick

Enter StorageClass name [default: default]: vsphere-standard
Enter data directory size per node (e.g., 50Gi, 100Gi) [default: 50Gi]: 100Gi
Enter max memory per node (e.g., 4Gi, 8Gi, 16Gi) [default: 8Gi]: 16Gi

[INFO] Configuration Summary:
  - Environment: On-Premise vSphere/vCenter
  - Namespace: mysql-prod
  - Cluster Name: pxc-cluster
  - Nodes: 3
  - Data Directory Size: 100Gi
  - Max Memory per Node: 16Gi
  - InnoDB Buffer Pool Size (70%): 11468M
  - Storage Class: vsphere-standard
  - PXC Version: 8.4.6-2
  - HAProxy Version: 2.8.15

Proceed with installation? (yes/no): yes
```

## Configuration

### Environment Variables

You can customize the installation by setting environment variables (or use interactive prompts):

```bash
# Custom namespace (or will be prompted)
NAMESPACE=my-percona ./percona/on-prem/install.sh

# Custom cluster name
CLUSTER_NAME=my-cluster ./percona/on-prem/install.sh

# Different number of nodes
PXC_NODES=5 ./percona/on-prem/install.sh
```

**Note**: If `NAMESPACE` is not set as an environment variable, the script will prompt you for it interactively.

### vSphere Storage Classes

Common vSphere storage class configurations:

```yaml
# Example: vsphere-standard StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: vsphere-standard
provisioner: kubernetes.io/vsphere-volume
parameters:
  diskformat: thin
  datastore: vsanDatastore
```

### Resource Calculations

The script automatically calculates optimal settings:
- **InnoDB Buffer Pool**: Set to 70% of max memory
- **Memory Requests**: Set to 80% of max memory
- **Memory Limits**: Set to max memory specified
- **CPU**: 1 CPU request, 2 CPU limit per node

### Host-Based Distribution

Pods are automatically distributed across worker nodes using:
- **Anti-affinity rules**: `kubernetes.io/hostname`
- **Pod Disruption Budget**: maxUnavailable = 1
- **3 nodes minimum**: Each PXC pod on different host

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
   - Secret: `percona-backup-minio` (MinIO credentials)
   - MinIO S3-compatible storage
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
- **Storage**: MinIO S3-compatible storage at `minio.minio.svc.cluster.local:9000`

**Note**: MinIO must be deployed separately. Install MinIO in the `minio` namespace:
```bash
helm repo add minio https://charts.min.io/
helm install minio minio/minio \
  --namespace minio --create-namespace \
  --set persistence.size=100Gi \
  --set mode=standalone
```

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
  storageName: minio
EOF

# Check backup status
kubectl describe pxc-backup manual-backup-TIMESTAMP -n percona

# Access MinIO console (port-forward)
kubectl port-forward -n minio svc/minio 9001:9001
# Open http://localhost:9001 in browser
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
kubectl get storageclass

# Check if PVCs are bound
kubectl get pvc -n percona

# Describe PVC for details
kubectl describe pvc datadir-pxc-cluster-pxc-0 -n percona
```

### vSphere-specific issues

```bash
# Check vSphere cloud provider
kubectl get pods -n kube-system -l component=cloud-controller-manager

# Check for vSphere CSI driver
kubectl get pods -n kube-system | grep vsphere-csi

# View vSphere provisioner logs
kubectl logs -n kube-system -l app=vsphere-csi-controller
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

To remove the entire cluster:

```bash
# Delete cluster
helm uninstall pxc-cluster -n percona

# Delete operator
helm uninstall percona-operator -n percona

# Delete PVCs (optional - will delete all data!)
kubectl delete pvc -n percona --all

# Delete namespace (optional)
kubectl delete namespace percona
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              vSphere/vCenter Kubernetes Cluster             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                   Namespace: percona                  │  │
│  │                                                       │  │
│  │  ┌─────────────────────────────────────────────┐     │  │
│  │  │         Percona Operator (Deployment)       │     │  │
│  │  └─────────────────────────────────────────────┘     │  │
│  │                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │   PXC-0     │  │   PXC-1     │  │   PXC-2     │  │  │
│  │  │  (host-1)   │  │  (host-2)   │  │  (host-3)   │  │  │
│  │  │  100Gi PV   │  │  100Gi PV   │  │  100Gi PV   │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  │                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │  HAProxy-0  │  │  HAProxy-1  │  │  HAProxy-2  │  │  │
│  │  │  (host-1)   │  │  (host-2)   │  │  (host-3)   │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  │                                                       │  │
│  │  Service: pxc-cluster-haproxy:3306                   │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                          ↓
                   vSAN Datastore
```

## vSphere Best Practices

### Storage Configuration

1. **Use vSAN or shared datastore**
   - Enables pod mobility across hosts
   - Better performance than local storage

2. **Thin provisioning**
   - Reduces initial storage footprint
   - Grows as data increases

3. **Separate datastores**
   - Consider separate datastores for PXC data vs other workloads
   - Improves I/O isolation

### Network Configuration

1. **Dedicated network segment**
   - Isolate database traffic from other workloads
   - Use vSphere distributed switches

2. **Pod network policies**
   - Restrict access to database namespace
   - Allow only necessary ingress/egress

### Resource Allocation

1. **DRS rules**
   - Use VM-VM anti-affinity in vSphere
   - Ensures worker nodes are on different ESXi hosts

2. **Resource pools**
   - Dedicate vCPU and memory reservations
   - Prevents resource contention

3. **Storage I/O control**
   - Use vSphere SIOC for QoS
   - Prioritize database I/O

## See Also

- [Percona Operator Documentation](https://docs.percona.com/percona-operator-for-mysql/pxc/)
- [vSphere Storage for Kubernetes](https://docs.vmware.com/en/VMware-vSphere-Container-Storage-Plug-in/)
- [HAProxy Configuration](https://www.haproxy.org/documentation/)
- [MySQL 8.4 Reference](https://dev.mysql.com/doc/refman/8.4/en/)
- [Load Testing Guide](../../monitoring/README.md)


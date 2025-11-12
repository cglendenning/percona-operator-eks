# Resource Management for Percona XtraDB Cluster

## Overview

The install scripts for both EKS and on-premise deployments now intelligently detect node resources and automatically calculate appropriate CPU and memory requests to prevent pod scheduling failures.

## Automatic Resource Detection

During installation, the scripts:

1. **Detect Node Capacity**
   - Query Kubernetes nodes for available CPU and memory
   - Account for system overhead (reserve 20% for kube-system pods)
   - Display actual node resources to the user

2. **Calculate Optimal Resource Requests**
   - **PXC CPU**: 70% of usable CPU per node (minimum 500m)
   - **HAProxy CPU**: 15% of usable CPU per node (minimum 50m)
   - Adjust based on cluster topology (3 PXC + 3 HAProxy pods distributed across 3 nodes)

3. **Validate Configuration**
   - Before installation, estimate total CPU/memory requirements
   - Compare against available node capacity
   - Warn user if configuration won't fit
   - Offer solutions:
     - Reduce PXC nodes from 3 to 2
     - Reduce HAProxy instances from 3 to 2
     - Use larger instance types/nodes

## Example: t3a.large (EKS)

**Node Capacity:**
- CPUs: 2 vCPUs per node
- Memory: ~7.6 GB per node

**Calculated Resources:**
- PXC CPU Request: 1120m (1.12 vCPUs)
- HAProxy CPU Request: 240m (0.24 vCPUs)
- Total per node: ~1360m for 2 pods (avg)

**System overhead:** ~400m reserved for kube-system

**Result:**
- 3 PXC pods × 1120m = 3360m total
- 3 HAProxy pods × 240m = 720m total
- Total cluster CPU request: 4080m
- With 3 nodes × 2000m (80% of 2 vCPUs) = 6000m available
- **Fits comfortably** with ~31% headroom

## Default Fallback Values

If node detection fails, the scripts use conservative defaults:

- **PXC CPU**: 600m (good for 2+ vCPU nodes)
- **HAProxy CPU**: 100m (minimal but functional)
- **PXC Memory**: 5Gi (safe for 8GB nodes)
- **HAProxy Memory**: 128Mi request, 512Mi limit

## Memory Configuration

The scripts prompt for memory per PXC node and automatically:

1. **Validate Memory Format**
   - Must be in format like `4Gi` or `8Gi`
   - Rejects invalid formats

2. **Check Against Node Capacity**
   - For t3a.large: warns if > 6Gi (too high for 8GB nodes)
   - Prompts for confirmation before proceeding
   - Suggests safe values based on node size

3. **Calculate InnoDB Buffer Pool**
   - Automatically sets to 70% of max memory
   - Optimizes for MySQL/InnoDB performance

## Installation Warnings

The install scripts will display warnings and pause for confirmation if:

### Memory Warning
```
[WARN] Memory request of 8Gi may be too high for t3a.large instances (8 GiB total)
[WARN] This will cause pods to be stuck in 'Pending' state
[INFO] Recommended: 5Gi or less to leave room for system overhead

Continue anyway? (yes/no) [no]:
```

### CPU Warning
```
[WARN] Configuration may not fit on nodes!
[WARN]   Estimated CPU per node: 1800m
[WARN]   Available CPU per node: 1600m (after system overhead)
[WARN] This may cause pods to be stuck in 'Pending' state

[INFO] Options to fix:
[INFO]   1. Reduce PXC nodes from 3 to 2
[INFO]   2. Reduce HAProxy instances from 3 to 2
[INFO]   3. Use larger instance type (e.g., t3a.xlarge)

Continue anyway? (yes/no) [no]:
```

## Troubleshooting Pod Scheduling Issues

If pods are stuck in `Pending` state:

### Check Node Resources
```bash
kubectl describe node | grep -A 5 "Allocated resources"
```

### Check Pod Events
```bash
kubectl describe pod <pod-name> -n percona
```

Look for messages like:
- `Insufficient cpu`
- `Insufficient memory`

### Solutions

#### Option 1: Reduce Resource Requests (Runtime)
```bash
# Reduce PXC CPU
kubectl patch pxc pxc-cluster-pxc-db -n percona --type='merge' \
  -p '{"spec":{"pxc":{"resources":{"requests":{"cpu":"600m"}}}}}'

# Reduce HAProxy CPU
kubectl patch pxc pxc-cluster-pxc-db -n percona --type='merge' \
  -p '{"spec":{"haproxy":{"resources":{"requests":{"cpu":"100m"}}}}}'
```

#### Option 2: Reduce Cluster Size (Runtime)
```bash
# Reduce to 2 PXC nodes
kubectl patch pxc pxc-cluster-pxc-db -n percona --type='merge' \
  -p '{"spec":{"pxc":{"size":2}}}'

# Reduce to 2 HAProxy instances
kubectl patch pxc pxc-cluster-pxc-db -n percona --type='merge' \
  -p '{"spec":{"haproxy":{"size":2}}}'
```

#### Option 3: Increase Node Size
- **EKS**: Update CloudFormation stack to use larger instance type (e.g., `t3a.xlarge` with 4 vCPUs)
- **On-Premise**: Add more CPU cores to your Kubernetes nodes

## Production Recommendations

### Minimum Node Requirements

For a 3-node PXC cluster with 3 HAProxy instances:

| Instance Type | vCPUs | Memory | Suitability |
|---------------|-------|--------|-------------|
| t3a.medium    | 2     | 4 GB   | ❌ Too small |
| t3a.large     | 2     | 8 GB   | ⚠️ Dev/Test only (tight fit) |
| t3a.xlarge    | 4     | 16 GB  | ✅ Recommended minimum |
| m5.xlarge     | 4     | 16 GB  | ✅ Better performance |
| m5.2xlarge    | 8     | 32 GB  | ✅ Production |

### Production Tuning

For production workloads:
- Use at least 4 vCPU nodes
- Allocate 8-16Gi memory per PXC node
- Enable dedicated monitoring
- Configure proper resource limits (2x requests)
- Plan for 30-40% headroom for bursts

## How Resource Detection Works

### Detection Logic
```bash
# Get node CPU capacity
node_cpus=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}')

# Calculate usable CPU (80% after system overhead)
usable_cpu=$(echo "$node_cpus * 0.80" | bc)

# Calculate per-pod CPU (70% for PXC, 15% for HAProxy)
pxc_cpu=$(echo "$usable_cpu * 0.70" | bc)
haproxy_cpu=$(echo "$usable_cpu * 0.15 * 1000" | bc)  # Convert to millicores
```

### Resource Allocation Formula

For a 3-node cluster with 3 PXC + 3 HAProxy pods:

```
Total CPU needed = (PXC_pods × PXC_cpu) + (HAProxy_pods × HAProxy_cpu)
Available CPU = Nodes × vCPUs × 0.80 (system overhead)

Schedulable = Total CPU needed ≤ Available CPU
```

### Pod Distribution

With 3 Kubernetes nodes and 6 total pods, the scheduler aims for:
- 2 pods per node (average)
- Anti-affinity rules spread PXC pods across different nodes/zones
- HAProxy pods distributed similarly

## Files Modified

- `percona/eks/install.sh`
  - Added `detect_node_resources()` function
  - Added CPU validation in `prompt_configuration()`
  - Updated Helm values to use `${RECOMMENDED_PXC_CPU:-600m}`
  - Updated Helm values to use `${RECOMMENDED_HAPROXY_CPU:-100m}`

- `percona/on-prem/install.sh`
  - Same enhancements as EKS script
  - Adapted for on-premise environments (vSphere/vCenter)

## Point-in-Time Recovery (PITR)

### PITR Configuration

PITR is automatically configured in both EKS and on-premise installations with the following settings:

**EKS (AWS S3):**
- Storage: S3 bucket `percona-eks-backups`
- Upload interval: 60 seconds
- GTID cache key: `pxc-pitr-cache`

**On-Premise (MinIO):**
- Storage: MinIO bucket `percona-backups`
- Endpoint: `http://minio.minio.svc.cluster.local:9000`
- Upload interval: 60 seconds
- GTID cache key: `pxc-pitr-cache`

### PITR Environment Variables

PITR requires the `GTID_CACHE_KEY` environment variable to be set. The install scripts automatically:

1. Wait for the PITR deployment to be created
2. Add the required environment variable
3. Verify the configuration

### Manual PITR Configuration

If you need to manually configure PITR on an existing cluster:

```bash
# Add GTID_CACHE_KEY to PITR deployment
kubectl patch deployment pxc-cluster-pxc-db-pitr -n percona --type='json' \
  -p '[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "GTID_CACHE_KEY", "value": "pxc-pitr-cache"}}]'
```

### PITR Troubleshooting

**Error: "required environment variable GTID_CACHE_KEY is not set"**
- The GTID_CACHE_KEY environment variable is missing
- Run the manual configuration command above

**Error: "bucket does not exist"**
- For EKS: Create the S3 bucket `percona-eks-backups`
- For on-prem: Ensure MinIO is running and bucket `percona-backups` exists

**Warning: "cache file not found"**
- Normal for first PITR run
- Cache will be built automatically

### PITR Storage Requirements

- **S3/EKS**: Bucket must exist and credentials must have write access
- **MinIO/On-prem**: MinIO service must be accessible at the configured endpoint
- **Network**: PITR pods need outbound connectivity to storage
- **Performance**: PITR uploads every 60 seconds, ensure sufficient bandwidth

## Benefits

1. **Prevents Scheduling Failures**: Detects capacity issues before installation
2. **Optimizes Performance**: Calculates appropriate CPU requests based on available resources
3. **User-Friendly**: Clear warnings and actionable suggestions
4. **Flexible**: Works with various node sizes from dev to production
5. **Safe Defaults**: Falls back to conservative values if detection fails
6. **PITR Ready**: Automatic Point-in-Time Recovery configuration


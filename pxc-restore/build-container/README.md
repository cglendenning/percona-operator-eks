# PXC Auto-Restore Controller

Kubernetes controller that automatically detects new successful backups in a source namespace and triggers restore operations in a destination cluster.

## Prerequisites

1. **Percona XtraDB Operator** must be installed in your cluster (provides the CRDs)
2. **Docker** or compatible container runtime
3. **kubectl** configured to access your cluster

## How It Works

The controller continuously monitors for:
- New `PerconaXtraDBClusterBackup` resources in the source namespace
- When a new successful backup is detected, it creates a `PerconaXtraDBClusterRestore` resource in the destination namespace
- Tracks the last restored backup to avoid duplicates

## Build

```bash
docker build -t pxc-auto-restore-controller:local .
```

If using k3d:
```bash
k3d image import pxc-auto-restore-controller:local -c <cluster-name>
```

## Deploy

### 1. Create Namespaces

```bash
kubectl create namespace <source-namespace>
kubectl create namespace <dest-namespace>
```

### 2. Create ServiceAccount

```bash
kubectl -n <dest-namespace> create serviceaccount pxc-auto-restore-sa
```

### 3. Apply RBAC Permissions

Replace `SOURCE_NS`, `DEST_NS`, and `DEST_SA` placeholders in the RBAC file:

```bash
# Edit pxc-restore/RBAC_for_sidecar.yaml and replace:
# - SOURCE_NS with your source namespace
# - DEST_NS with your destination namespace  
# - DEST_SA with pxc-auto-restore-sa

kubectl apply -f ../RBAC_for_sidecar.yaml
```

Or apply directly with substitutions:

```bash
cat ../RBAC_for_sidecar.yaml | \
  sed 's/SOURCE_NS/source-namespace/g' | \
  sed 's/DEST_NS/wookie-restore/g' | \
  sed 's/DEST_SA/pxc-auto-restore-sa/g' | \
  kubectl apply -f -
```

### 4. Deploy Controller

Edit the environment variables in the Pod spec below:

```bash
kubectl -n <dest-namespace> apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: pxc-auto-restore-controller
spec:
  serviceAccountName: pxc-auto-restore-sa
  restartPolicy: Always
  containers:
    - name: controller
      image: pxc-auto-restore-controller:local
      imagePullPolicy: IfNotPresent
      env:
        - name: SOURCE_NS
          value: source-namespace           # Namespace where backups are created
        - name: DEST_NS
          value: wookie-restore             # Namespace where restores will be created
        - name: DEST_PXC_CLUSTER
          value: cluster1                   # Name of the PXC cluster to restore to
        - name: DEST_STORAGE_NAME
          value: s3-us-west                 # Storage name in the PXC cluster spec
        - name: TRACKING_CM
          value: pxc-restore-tracker        # ConfigMap name for tracking state
        - name: SLEEP_SECONDS
          value: "60"                       # Poll interval in seconds
        - name: S3_CREDENTIALS_SECRET
          value: s3-credentials             # Secret containing S3 access credentials
        - name: S3_REGION
          value: us-east-1                  # S3 region
        - name: S3_ENDPOINT_URL
          value: https://s3.us-east-1.amazonaws.com  # S3 endpoint URL
        # Optional: Override CRD version (defaults to v1)
        # - name: PXC_API_VERSION
        #   value: "v1"
YAML
```

## Troubleshooting

### "ERROR: HTTP request failed" with status=403

**Cause**: Missing RBAC permissions

**Solution**: Apply the RBAC configuration from `../RBAC_for_sidecar.yaml`. The ServiceAccount needs:
- Read access to `perconaxtradbclusterbackups` in the source namespace
- Create/read/update access to `perconaxtradbclusterrestores` in the destination namespace
- Create/read/update access to `configmaps` in the destination namespace

### "ERROR: HTTP request failed" with status=404

**Cause**: Percona XtraDB Operator CRDs not installed

**Solution**: Install the Percona Operator:
```bash
kubectl apply -f https://raw.githubusercontent.com/percona/percona-xtradb-cluster-operator/main/deploy/bundle.yaml
```

### "ERROR: HTTP request failed" with DNS/timeout errors

**Cause**: Pod cannot reach Kubernetes API server

**Solution**: Check network policies, DNS configuration, and API server endpoint

### Controller not picking up backups

Check the logs:
```bash
kubectl logs pxc-auto-restore-controller -n <dest-namespace> --follow
```

Verify backups exist and are in Succeeded state:
```bash
kubectl get perconaxtradbclusterbackups -n <source-namespace>
```

Check the tracking ConfigMap:
```bash
kubectl get configmap pxc-restore-tracker -n <dest-namespace> -o yaml
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SOURCE_NS` | Yes | Namespace to monitor for backups |
| `DEST_NS` | Yes | Namespace to create restore resources |
| `DEST_PXC_CLUSTER` | Yes | Name of the PXC cluster to restore to |
| `DEST_STORAGE_NAME` | Yes | Storage configuration name from PXC cluster spec |
| `TRACKING_CM` | Yes | ConfigMap name for tracking last restore |
| `SLEEP_SECONDS` | Yes | Seconds between backup checks |
| `S3_CREDENTIALS_SECRET` | Yes | Secret containing S3 access credentials |
| `S3_REGION` | Yes | S3 region (e.g., us-east-1) |
| `S3_ENDPOINT_URL` | Yes | S3 endpoint URL |
| `PXC_API_VERSION` | No | CRD API version (default: v1) |

## How the Error Messages Work

The controller includes detailed error formatting via `formatK8sError()` that provides:
- HTTP status code and method
- Kubernetes API error messages and reasons
- Full response body (truncated to 2000 chars)
- Hints for common issues (DNS, timeout, TLS, RBAC)

Example error:
```
ERROR: HTTP request failed status=403 method=GET reason="Forbidden" 
k8sMessage="perconaxtradbclusterrestores.pxc.percona.com is forbidden: User \"system:serviceaccount:wookie-restore:pxc-auto-restore-sa\" cannot list resource..." 
hint="RBAC Forbidden (check ClusterRole/Binding + ServiceAccount)"
```

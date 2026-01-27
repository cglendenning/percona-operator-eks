# SeaweedFS Tutorial - Multi-Namespace Replication

This tutorial walks you through deploying SeaweedFS to two namespaces in a single k3d cluster and setting up replication between them.

## Prerequisites

- Nix installed and configured
- Docker running (for k3d)
- kubectl installed (or available via nix)

## Quick Start - Copy/Paste Commands

```bash
# 1. Get the chart hash (first time only)
cd nix/wookie-nixpkgs
nix build .#seaweedfs-manifests
# If hash error, update charts.nix with the correct hash from error message

# 2. Deploy everything
nix run .#seaweedfs-up

# 3. Wait for pods to be ready
kubectl wait --for=condition=ready pod -n seaweedfs-primary -l app=seaweedfs --timeout=120s
kubectl wait --for=condition=ready pod -n seaweedfs-secondary -l app=seaweedfs --timeout=120s

# 4. Test replication
cd ../../seaweedfs_tutorial
./test-replication.sh

# 5. Cleanup when done
cd ../nix/wookie-nixpkgs
nix run .#seaweedfs-down
```

## Step 1: Get the Chart Hash

First, we need to get the correct hash for the SeaweedFS Helm chart. The chart is configured in `nix/wookie-nixpkgs/pkgs/charts/charts.nix` with a placeholder hash.

```bash
cd nix/wookie-nixpkgs
nix build .#seaweedfs-manifests
```

If the build fails with a hash mismatch, copy the correct hash from the error message and update `nix/wookie-nixpkgs/pkgs/charts/charts.nix`:

```nix
seaweedfs = {
  "4_0_406" = kubelib.downloadHelmChart {
    repo = seaweedfs-repo;
    chart = "seaweedfs";
    version = "4.0.406";
    chartHash = "sha256-XXXXX...";  # Replace with the hash from the error
  };
};
```

## Step 2: Build the Configuration

Build the SeaweedFS tutorial configuration:

```bash
cd nix/wookie-nixpkgs
nix build .#seaweedfs-helmfile
```

This generates the helmfile.yaml that will deploy SeaweedFS to both namespaces.

## Step 3: Create the k3d Cluster

Create the k3d cluster for the tutorial:

```bash
cd nix/wookie-nixpkgs
nix run .#seaweedfs-up
```

Or manually:

```bash
cd nix/wookie-nixpkgs
$(nix build .#seaweedfs-create-cluster --print-out-paths)/bin/create-k3d-cluster
```

This creates a k3d cluster named `seaweedfs-tutorial` with:
- 1 server node
- 2 agent nodes
- Traefik disabled (not needed for this tutorial)

## Step 4: Deploy SeaweedFS

Deploy SeaweedFS to both namespaces using helmfile:

```bash
cd nix/wookie-nixpkgs
CLUSTER_CONTEXT=k3d-seaweedfs-tutorial $(nix build .#seaweedfs-deploy --print-out-paths)/bin/deploy-seaweedfs-tutorial-helmfile
```

Or use the convenience script:

```bash
cd nix/wookie-nixpkgs
nix run .#seaweedfs-up
```

This will:
1. Create the `seaweedfs-primary` and `seaweedfs-secondary` namespaces
2. Deploy SeaweedFS master, volume, and filer components to each namespace
3. Enable S3 API in both filers

## Step 5: Verify Deployment

Check that all pods are running:

```bash
kubectl get pods -n seaweedfs-primary
kubectl get pods -n seaweedfs-secondary
```

You should see:
- 1 master pod
- 1 volume pod
- 1 filer pod

In each namespace.

Check the services:

```bash
kubectl get svc -n seaweedfs-primary
kubectl get svc -n seaweedfs-secondary
```

## Step 6: Configure Replication

SeaweedFS replication is configured via the filer's environment variables. The current setup uses `WEED_REPLICATION = "001"` which means 1 replica.

To set up replication between the two namespaces, we need to configure the filers to know about each other. This is done by setting up remote mount points.

### Get Filer Service Addresses

```bash
PRIMARY_FILER=$(kubectl get svc -n seaweedfs-primary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')
SECONDARY_FILER=$(kubectl get svc -n seaweedfs-secondary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')

echo "Primary filer: $PRIMARY_FILER.seaweedfs-primary.svc.cluster.local:8888"
echo "Secondary filer: $SECONDARY_FILER.seaweedfs-secondary.svc.cluster.local:8888"
```

### Configure Remote Mount (Replication)

Port-forward to the primary filer:

```bash
kubectl port-forward -n seaweedfs-primary svc/$PRIMARY_FILER 8888:8888
```

In another terminal, configure a remote mount to the secondary namespace:

```bash
# Get the secondary filer service name
SECONDARY_FILER=$(kubectl get svc -n seaweedfs-secondary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')

# Configure remote mount via filer API
curl -X POST http://localhost:8888/admin/remote_mount \
  -d "filer=$SECONDARY_FILER.seaweedfs-secondary.svc.cluster.local:8888" \
  -d "dir=/secondary"
```

Alternatively, you can use the SeaweedFS shell (weed) to configure replication. First, get a shell in the primary filer pod:

```bash
PRIMARY_FILER_POD=$(kubectl get pod -n seaweedfs-primary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n seaweedfs-primary $PRIMARY_FILER_POD -- sh
```

Inside the pod, configure the remote mount:

```bash
weed mount -filer=$SECONDARY_FILER.seaweedfs-secondary.svc.cluster.local:8888 -dir=/secondary
```

## Step 7: Test Replication

### Option 1: Use the Test Script

A test script is provided to automate replication testing:

```bash
cd seaweedfs_tutorial
./test-replication.sh
```

This script will:
1. Create a test bucket in the primary namespace
2. Upload a test file
3. Wait for replication
4. Verify the file exists in the secondary namespace
5. Download and verify file content

### Option 2: Manual Testing

### Create a Bucket and Upload Data

Port-forward to the primary filer S3 endpoint:

```bash
PRIMARY_FILER=$(kubectl get svc -n seaweedfs-primary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n seaweedfs-primary svc/$PRIMARY_FILER 8333:8333
```

In another terminal, use the AWS CLI or curl to create a bucket and upload a file:

```bash
# Create a bucket
aws --endpoint-url=http://localhost:8333 s3 mb s3://test-bucket

# Create a test file
echo "Hello from primary namespace!" > test-file.txt

# Upload the file
aws --endpoint-url=http://localhost:8333 s3 cp test-file.txt s3://test-bucket/
```

### Verify Replication to Secondary Namespace

Port-forward to the secondary filer:

```bash
SECONDARY_FILER=$(kubectl get svc -n seaweedfs-secondary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n seaweedfs-secondary svc/$SECONDARY_FILER 8334:8333
```

Check if the bucket and file exist in the secondary namespace:

```bash
# List buckets
aws --endpoint-url=http://localhost:8334 s3 ls

# List objects in the bucket
aws --endpoint-url=http://localhost:8334 s3 ls s3://test-bucket/

# Download and verify the file
aws --endpoint-url=http://localhost:8334 s3 cp s3://test-bucket/test-file.txt downloaded-file.txt
cat downloaded-file.txt
```

You should see the same file content in both namespaces, confirming replication is working.

## Step 8: Cleanup

To tear down the entire stack:

```bash
cd nix/wookie-nixpkgs
nix run .#seaweedfs-down
```

Or manually:

```bash
cd nix/wookie-nixpkgs
$(nix build .#seaweedfs-delete-cluster --print-out-paths)/bin/delete-k3d-cluster
```

## Troubleshooting

### Pods not starting

Check pod logs:

```bash
kubectl logs -n seaweedfs-primary -l app=seaweedfs,component=master
kubectl logs -n seaweedfs-primary -l app=seaweedfs,component=volume
kubectl logs -n seaweedfs-primary -l app=seaweedfs,component=filer
```

### Storage issues

k3d uses `local-path` storage class by default. Check if PVCs are bound:

```bash
kubectl get pvc -n seaweedfs-primary
kubectl get pvc -n seaweedfs-secondary
```

### Replication not working

1. Verify network connectivity between namespaces:
   ```bash
   PRIMARY_FILER_POD=$(kubectl get pod -n seaweedfs-primary -l app=seaweedfs,component=filer -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n seaweedfs-primary $PRIMARY_FILER_POD -- wget -O- http://$SECONDARY_FILER.seaweedfs-secondary.svc.cluster.local:8888/
   ```

2. Check filer logs for replication errors:
   ```bash
   kubectl logs -n seaweedfs-primary -l app=seaweedfs,component=filer | grep -i replication
   ```

## Next Steps

- Configure more sophisticated replication policies
- Set up cross-cluster replication (requires network connectivity between clusters)
- Enable authentication for S3 access
- Configure volume server replication for data durability
- Set up monitoring and alerting

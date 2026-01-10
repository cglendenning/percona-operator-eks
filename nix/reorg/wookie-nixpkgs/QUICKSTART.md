# Wookie-NixPkgs Quick Start

Complete guide to deploying Wookie (Istio + PXC) using Fleet.

## Prerequisites

- Nix with flakes enabled
- kubectl
- k3d (for local testing)

## Step-by-Step Guide

### 1. Get Chart Hashes (One-Time)

Nix will tell you the correct hashes automatically:

```bash
cd /Users/craig/percona_operator/nix/reorg/wookie-nixpkgs

# Try to build (it will fail with hash mismatch)
nix build .#fleet-bundles
```

**Expected output (for first chart):**
```
error: hash mismatch in file downloaded from 'https://istio-release.storage.googleapis.com/charts/base-1.24.2.tgz':
  specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  got:       sha256-abc123xyz456...  ← COPY THIS HASH
```

**Update `pkgs/charts/charts.nix`** with the hash from the error:

```nix
istio-base = {
  "1_24_2" = kubelib.downloadHelmChart {
    repo = istio-repo;
    chart = "base";
    version = "1.24.2";
    chartHash = "sha256-abc123xyz456...";  # ← Paste the "got:" hash here
  };
};
```

**Repeat** for each chart:
1. Build again: `nix build .#fleet-bundles`
2. It will fail on the next chart (istiod)
3. Copy the "got:" hash
4. Update `charts.nix`
5. Continue until all 3 charts have correct hashes
6. Build will succeed!

### 2. Create k3d Cluster

```bash
# Create a local Kubernetes cluster
nix run .#create-cluster

# Verify it's running
kubectl cluster-info --context k3d-wookie-local
kubectl get nodes --context k3d-wookie-local
```

### 3. Install Fleet

```bash
# Install Fleet CRDs
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet-crd.yaml

# Install Fleet controller
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet.yaml

# Wait for Fleet to be ready (takes ~1-2 minutes)
kubectl wait --for=condition=available --timeout=300s \
  deployment/fleet-controller -n cattle-fleet-system

# Verify Fleet is running
kubectl get pods -n cattle-fleet-system
```

### 4. Build Fleet Bundles

```bash
# Build all Fleet bundles
nix build .#fleet-bundles

# View the generated bundles
ls -la result/
# crds.yaml
# namespaces.yaml
# operators.yaml
# services.yaml

# Inspect a bundle (optional)
cat result/crds.yaml | head -50
```

### 5. Deploy Wookie

```bash
# Deploy all bundles via Fleet
nix run .#deploy-fleet
```

**Expected output:**
```
=== Deploying Wookie via Fleet ===

Target cluster: k3d-wookie-local

Fleet detected. Applying bundles...

Applying crds bundle...
bundle.fleet.cattle.io/crds created

Applying namespaces bundle...
bundle.fleet.cattle.io/namespaces created

Applying operators bundle...
bundle.fleet.cattle.io/operators created

Applying services bundle...
bundle.fleet.cattle.io/services created

=== Fleet bundles applied ===

Monitor deployment status:
  kubectl get bundles -n fleet-local --context k3d-wookie-local
```

### 6. Monitor Deployment

```bash
# Watch Fleet bundles
kubectl get bundles -n fleet-local -w

# Expected progression:
# NAME          BUNDLEDEPLOYMENTS   READY   STATUS
# crds          0/1                 False   Pending
# crds          1/1                 True    Ready
# namespaces    1/1                 True    Ready
# operators     0/1                 False   Pending
# operators     1/1                 True    Ready
# services      1/1                 True    Ready
```

In another terminal:
```bash
# Watch Istio pods coming up
kubectl get pods -n istio-system -w

# Expected:
# NAME                      READY   STATUS    RESTARTS   AGE
# istiod-xxxxx-yyyyy       1/1     Running   0          60s
```

### 7. Verify Deployment

```bash
# Check all Istio components
kubectl get all -n istio-system

# Check Istio CRDs
kubectl get crds | grep istio

# Check Wookie namespace
kubectl get ns wookie

# Verify Istiod is healthy
kubectl get deployment istiod -n istio-system
```

### 8. View Configuration

```bash
# See what Fleet deployed
kubectl get bundledeployments -A

# View a specific bundle's resources
kubectl get bundle operators -n fleet-local -o yaml
```

## Troubleshooting

### Chart Hash Errors

**Problem:**
```
error: hash mismatch in file downloaded from 'https://...'
  specified: sha256-AAAA...
  got:       sha256-BBBB...
```

**Solution:**
- Rerun `./scripts/fetch-chart-hashes.sh` and update `pkgs/charts/charts.nix` with the correct hashes

### Fleet Not Found

**Problem:**
```
ERROR: Fleet CRDs not found
```

**Solution:**
```bash
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet-crd.yaml
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet.yaml
```

### Bundle Stuck in Pending

**Problem:**
```
operators     0/1     False   Pending
```

**Solution:**
```bash
# Check bundle status
kubectl describe bundle operators -n fleet-local

# Check if dependencies are met
kubectl get bundle namespaces -n fleet-local

# Check Fleet controller logs
kubectl logs -n cattle-fleet-system deployment/fleet-controller
```

### Istiod Not Starting

**Problem:**
```
istiod-xxxxx   0/1   CrashLoopBackOff
```

**Solution:**
```bash
# Check Istiod logs
kubectl logs -n istio-system deployment/istiod

# Common issue: CRDs not ready
kubectl get crds | grep istio
kubectl wait --for condition=established --all crd --timeout=120s

# Check if validation webhooks are causing issues
kubectl get validatingwebhookconfigurations
```

## Clean Up

```bash
# Delete Fleet bundles
kubectl delete bundles --all -n fleet-local

# Delete cluster
nix run .#delete-cluster
```

## Next Steps

### Multi-Cluster Setup

1. Edit configuration for multi-cluster:
   ```nix
   projects.wookie = {
     clusterRole = "primary";  # or "dr"
     istio.eastWestGateway.enabled = true;
   };
   ```

2. Rebuild and deploy:
   ```bash
   nix build .#fleet-bundles --rebuild
   nix run .#deploy-fleet
   ```

### Add PXC

1. Implement `modules/projects/wookie/pxc.nix`
2. Enable in configuration:
   ```nix
   projects.wookie = {
     istio.enable = true;
     pxc.enable = true;
   };
   ```

### GitOps with Fleet

1. Build and commit Fleet bundles:
   ```bash
   nix build .#fleet-bundles
   cp -r result/ fleet/
   git add fleet/
   git commit -m "Update deployment"
   git push
   ```

2. Configure Fleet GitRepo:
   ```yaml
   apiVersion: fleet.cattle.io/v1alpha1
   kind: GitRepo
   metadata:
     name: wookie
     namespace: fleet-local
   spec:
     repo: https://github.com/yourorg/wookie-config
     branch: main
     paths: [fleet]
   ```

3. Fleet auto-deploys from git!

## Reference

- [Full README](README.md)
- [Fleet Deployment Guide](FLEET_DEPLOYMENT.md)
- [Implementation Status](IMPLEMENTATION_STATUS.md)

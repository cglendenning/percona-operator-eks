# Fleet-Based Deployment Guide

This guide covers deploying Wookie (Istio + PXC) using Rancher Fleet for GitOps-style deployments.

## Prerequisites

### 1. Install Fleet on Your Cluster

First, you need a Kubernetes cluster with Fleet installed:

```bash
# Create a cluster
nix run .#create-cluster

# Install Fleet CRDs
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet-crd.yaml

# Install Fleet controller
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet.yaml

# Wait for Fleet to be ready
kubectl wait --for=condition=available --timeout=300s deployment/fleet-controller -n cattle-fleet-system
```

### 2. Get Helm Chart Hashes

Nix will automatically tell you the correct hashes when you try to build:

```bash
cd /Users/craig/percona_operator/nix/reorg/wookie-nixpkgs

# Try to build - it will fail with hash mismatch
nix build .#fleet-bundles
```

The error will show:
```
error: hash mismatch in file downloaded from '...':
  specified: sha256-AAAA...
  got:       sha256-CORRECT_HASH_HERE  ← Copy this
```

Update `pkgs/charts/charts.nix` with the "got:" hash, then build again. Repeat for all 3 charts.

## Build Fleet Bundles

### Build All Bundles

```bash
# Build all Fleet bundles
nix build .#fleet-bundles

# View the generated bundles
tree result/
# result/
# ├── crds.yaml
# ├── namespaces.yaml
# ├── operators.yaml
# └── services.yaml
```

### Build Individual Bundles

For debugging, you can build individual batch bundles:

```bash
# Build just CRDs
nix build .#fleet-bundle-crds

# Build just namespaces
nix build .#fleet-bundle-namespaces

# Build operators (Istiod)
nix build .#fleet-bundle-operators

# Build services
nix build .#fleet-bundle-services
```

## Deploy to Cluster

### Option 1: Automated Deployment Script

Use the provided deployment script:

```bash
# Deploy all Fleet bundles
nix run .#deploy-fleet

# This will:
# 1. Check if Fleet is installed
# 2. Apply bundles in order (crds → namespaces → operators → services)
# 3. Show monitoring commands
```

### Option 2: Manual Deployment

Apply bundles manually for more control:

```bash
# Build the bundles first
nix build .#fleet-bundles

# Apply in order (respect dependencies)
kubectl apply -f result/crds.yaml
kubectl apply -f result/namespaces.yaml
kubectl apply -f result/operators.yaml
kubectl apply -f result/services.yaml
```

## Monitor Deployment

### Check Fleet Bundles

```bash
# List all Fleet bundles
kubectl get bundles -n fleet-local

# Expected output:
# NAME          BUNDLEDEPLOYMENTS   READY   STATUS
# crds          1/1                 True    
# namespaces    1/1                 True    
# operators     1/1                 True    
# services      1/1                 True    
```

### Check Bundle Deployments

```bash
# List bundle deployments (actual deployed resources)
kubectl get bundledeployments -A

# Check specific bundle deployment
kubectl get bundledeployment crds-local -n fleet-local -o yaml
```

### Check Deployed Resources

```bash
# Check Istio CRDs
kubectl get crds | grep istio

# Check namespaces
kubectl get ns istio-system wookie

# Check Istio pods
kubectl get pods -n istio-system

# Check Wookie pods (when PXC is added)
kubectl get pods -n wookie
```

## Troubleshooting

### Bundle Not Deploying

```bash
# Check bundle status
kubectl describe bundle <bundle-name> -n fleet-local

# Check bundle deployment logs
kubectl logs -n fleet-local deployment/fleet-controller

# Common issues:
# - Dependencies not met (check dependsOn in bundle spec)
# - CRDs not established (wait for CRDs before applying operators)
# - Invalid manifests (check syntax in generated YAML)
```

### View Generated Manifests

```bash
# Extract manifests from a bundle to inspect
kubectl get bundle crds -n fleet-local -o jsonpath='{.spec.resources[*].content}' | yq eval -
```

### Redeploy After Changes

```bash
# Rebuild with changes
nix build .#fleet-bundles --rebuild

# Delete and reapply bundles
kubectl delete bundle crds namespaces operators services -n fleet-local
nix run .#deploy-fleet
```

## Fleet Bundle Structure

Each generated Fleet bundle has this structure:

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: Bundle
metadata:
  name: operators  # Batch name
  namespace: fleet-local
  labels:
    wookie.io/batch: operators
    wookie.io/priority: "300"  # Deployment order
spec:
  targets:
  - clusterSelector: {}  # Deploy to all clusters
  
  correctDrift:
    enabled: true  # Auto-correct drift
    force: false
    keepFailHistory: true
  
  dependsOn:  # Wait for these bundles first
  - selector:
      matchLabels:
        wookie.io/batch: namespaces
  
  resources:  # Actual Kubernetes manifests
  - name: istiod
    content: |
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: istiod
        namespace: istio-system
      ---
      # ... (rendered Helm chart manifests)
```

## CI/CD Integration

### GitOps Workflow

1. **Build Fleet bundles** in CI:
   ```bash
   nix build .#fleet-bundles
   cp -r result/ fleet/
   git add fleet/
   git commit -m "Update Fleet bundles"
   git push
   ```

2. **Configure Fleet GitRepo**:
   ```yaml
   apiVersion: fleet.cattle.io/v1alpha1
   kind: GitRepo
   metadata:
     name: wookie-deployment
     namespace: fleet-local
   spec:
     repo: https://github.com/yourorg/wookie-config
     branch: main
     paths:
     - fleet
     targets:
     - clusterSelector: {}
   ```

3. **Fleet auto-deploys** from git repository

### Multi-Cluster Deployment

Deploy to multiple clusters using cluster selectors:

```nix
# In your configuration
targets = [
  {
    clusterSelector = {
      matchLabels = {
        env = "production";
        region = "us-east";
      };
    };
  }
];
```

## Advanced Configuration

### Custom Fleet Options

Modify `lib/fleet.nix` to add custom Fleet options:

```nix
spec = {
  # ... existing spec ...
  
  # Add custom options
  timeout = 300;  # Deployment timeout
  rollbackOnFailure = true;
  
  # Resource limits
  limits = {
    cpu = "1000m";
    memory = "1Gi";
  };
};
```

### Multi-Network Multi-Cluster

For Wookie's multi-cluster PXC setup:

```nix
# Cluster A (primary)
projects.wookie = {
  clusterRole = "primary";
  istio = {
    enable = true;
    eastWestGateway.enabled = true;
  };
};

# Cluster B (DR)
projects.wookie = {
  clusterRole = "dr";
  istio = {
    enable = true;
    eastWestGateway.enabled = true;
  };
};
```

This will generate separate Fleet bundles for each cluster with appropriate multi-cluster Istio configuration.

## Next Steps

1. **Add PXC Component**: Implement `modules/projects/wookie/pxc.nix`
2. **Add Monitoring**: Implement `modules/projects/wookie/monitoring.nix`
3. **Multi-Cluster Targets**: Create `modules/targets/production.nix` with multi-cluster support
4. **Testing**: Implement automated tests for Fleet bundles

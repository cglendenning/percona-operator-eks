# Wookie NixPkgs

Declarative Kubernetes deployment system using Nix.

## Quick Deploy

### Single-Cluster Setup

#### 1. Get Chart Hashes

```bash
# Build will fail and show you the correct hash
nix build .#manifests
```

Copy the `got: sha256-XXXXX...` hash from the error into `pkgs/charts/charts.nix`. Repeat for each chart.

#### 2. Create Cluster

```bash
nix run .#create-cluster
```

#### 3. Deploy

```bash
# Deploy via helmfile
nix run .#deploy

# Or view diff first
nix run .#diff
```

#### 4. Verify

```bash
kubectl get pods -n istio-system
kubectl get pods -n wookie
```

#### 5. Clean Up

```bash
nix run .#delete-cluster
```

### Multi-Cluster Setup

For cross-datacenter Istio multi-primary multi-network setup, see [MULTI_CLUSTER.md](./MULTI_CLUSTER.md).

Quick start:
```bash
nix run .#create-clusters             # Create cluster-a and cluster-b
nix run .#deploy-multi-cluster-istio  # Deploy Istio to both clusters
nix run .#test-multi-cluster          # Test cross-cluster connectivity
nix run .#delete-clusters             # Cleanup
```

## Architecture

```
modules/
├── platform/
│   ├── kubernetes/        # Batch/bundle deployment system
│   └── backends/
│       └── helmfile.nix   # Helmfile backend for deployment
├── projects/wookie/       # Wookie project (Istio + PXC)
│   ├── istio.nix         # Istio component
│   └── pxc.nix           # PXC component (future)
└── targets/              # Deployment targets (local, prod, dr)
```

Deployment uses helmfile to orchestrate Helm releases with proper dependency ordering.

## Configuration

Edit `flake.nix` to customize:

```nix
projects.wookie = {
  enable = true;
  clusterRole = "standalone";  # or "primary", "dr"
  
  istio = {
    enable = true;
    version = "1_28_2";
    eastWestGateway.enabled = false;  # true for multi-cluster
  };
};
```

## Available Commands

### Single-Cluster
```bash
nix run .#create-cluster       # Create k3d cluster
nix run .#delete-cluster       # Delete cluster
nix build .#manifests          # Build Kubernetes manifests
nix build .#helmfile           # Build helmfile.yaml
nix run .#deploy               # Deploy to cluster (via helmfile)
nix run .#diff                 # Show deployment diff
nix run .#destroy              # Destroy all releases
```

### Multi-Cluster
```bash
nix run .#create-clusters             # Create cluster-a and cluster-b
nix run .#delete-clusters             # Delete both clusters
nix run .#status-clusters             # Show cluster status
nix run .#deploy-multi-cluster-istio  # Deploy to both clusters (via helmfile)
nix run .#deploy-cluster-a            # Deploy only to cluster-a
nix run .#deploy-cluster-b            # Deploy only to cluster-b
nix run .#diff-cluster-a              # Show cluster-a diff
nix run .#diff-cluster-b              # Show cluster-b diff
nix run .#test-multi-cluster          # Test cross-cluster connectivity
```

### Development
```bash
nix develop                    # Dev shell with tools
```

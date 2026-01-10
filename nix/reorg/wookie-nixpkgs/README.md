# Wookie NixPkgs

Declarative Kubernetes deployment system using Nix.

## Quick Deploy

### 1. Get Chart Hashes

```bash
# Build will fail and show you the correct hash
nix build .#manifests
```

Copy the `got: sha256-XXXXX...` hash from the error into `pkgs/charts/charts.nix`. Repeat for each chart.

### 2. Create Cluster

```bash
nix run .#create-cluster
```

### 3. Deploy

```bash
nix run .#deploy
```

### 4. Verify

```bash
kubectl get pods -n istio-system
kubectl get pods -n wookie
```

## Clean Up

```bash
nix run .#delete-cluster
```

## Architecture

```
modules/
├── platform/kubernetes/    # Batch/bundle deployment system
├── projects/wookie/        # Wookie project (Istio + PXC)
│   ├── istio.nix          # Istio component
│   └── pxc.nix            # PXC component (future)
└── targets/               # Deployment targets (local, prod, dr)
```

## Configuration

Edit `flake.nix` to customize:

```nix
projects.wookie = {
  enable = true;
  clusterRole = "standalone";  # or "primary", "dr"
  
  istio = {
    enable = true;
    version = "1_24_2";
    eastWestGateway.enabled = false;  # true for multi-cluster
  };
};
```

## Available Commands

```bash
nix run .#create-cluster       # Create k3d cluster
nix run .#delete-cluster       # Delete cluster
nix build .#manifests          # Build Kubernetes manifests
nix run .#deploy               # Deploy to cluster
nix develop                    # Dev shell with tools
```

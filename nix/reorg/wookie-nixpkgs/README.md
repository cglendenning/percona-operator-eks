# Wookie NixPkgs

Declarative Kubernetes deployment system using Nix and Fleet.

## Quick Deploy

### 1. Get Chart Hashes

```bash
# Build will fail and show you the correct hash
nix build .#fleet-bundles
```

Copy the `got: sha256-XXXXX...` hash from the error into `pkgs/charts/charts.nix`. Repeat for each chart.

### 2. Create Cluster

```bash
nix run .#create-cluster
```

### 3. Install Fleet

```bash
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet-crd.yaml
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet.yaml
kubectl wait --for=condition=available --timeout=300s deployment/fleet-controller -n cattle-fleet-system
```

### 4. Deploy

```bash
nix run .#deploy-fleet
```

### 5. Verify

```bash
kubectl get bundles -n fleet-local
kubectl get pods -n istio-system -w
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
nix build .#fleet-bundles      # Build all Fleet bundles
nix run .#deploy-fleet         # Deploy to cluster
nix develop                    # Dev shell with tools
```

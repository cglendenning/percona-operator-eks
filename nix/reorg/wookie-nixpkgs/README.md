# Wookie NixPkgs

A NixOS-style module system for declarative Kubernetes deployments via Fleet.

**📚 Quick Links:**
- [Quick Start Guide](QUICKSTART.md) - Step-by-step deployment instructions
- [Fleet Deployment Guide](FLEET_DEPLOYMENT.md) - Detailed Fleet configuration
- [Implementation Status](IMPLEMENTATION_STATUS.md) - What's implemented vs planned

## Architecture

```
wookie-nixpkgs/
├── lib/                      # Shared utility functions
│   ├── helpers/             # Generic Nix helpers
│   ├── platform-tools/      # Platform-specific utilities
│   ├── certs/               # Certificate management
│   └── default.nix          # Exports all lib functions
├── modules/
│   ├── platform/            # Platform-level abstractions
│   │   └── kubernetes/      # Kubernetes batch/bundle system
│   ├── projects/            # Project-specific modules
│   │   └── wookie/         # Wookie project (PXC + Istio)
│   │       ├── default.nix # Main project module
│   │       ├── istio.nix   # Istio component
│   │       └── pxc.nix     # PXC component (future)
│   └── targets/            # Deployment target definitions
│       └── local-k3d.nix   # Local k3d cluster target
└── pkgs/
    └── charts/             # Helm chart definitions
        └── charts.nix      # Chart catalog
```

## Quick Start

### 1. Get Chart Hashes (One-Time Setup)

```bash
cd /Users/craig/percona_operator/nix/reorg/wookie-nixpkgs

# Try to build - Nix will tell you the correct hashes
nix build .#fleet-bundles

# Each error shows: "got: sha256-XXXXX..."
# Copy that hash to pkgs/charts/charts.nix
# Repeat until all 3 charts have correct hashes
```

### 2. Create a Local k3d Cluster

```bash
# Create the k3d cluster
nix run .#create-cluster

# Verify cluster is running
kubectl cluster-info --context k3d-wookie-local
```

### 3. Install Fleet

```bash
# Install Fleet CRDs and controller
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet-crd.yaml
kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet.yaml

# Wait for Fleet to be ready
kubectl wait --for=condition=available --timeout=300s deployment/fleet-controller -n cattle-fleet-system
```

### 4. Build and Deploy Wookie Project

```bash
# Build Fleet bundles
nix build .#fleet-bundles

# Deploy via Fleet
nix run .#deploy-fleet

# Monitor deployment
kubectl get bundles -n fleet-local
kubectl get bundledeployments -A
kubectl get pods -n istio-system
```

**For detailed deployment instructions, see [FLEET_DEPLOYMENT.md](FLEET_DEPLOYMENT.md)**

### 5. Clean Up

```bash
nix run .#delete-cluster
```

## Deployment Method

This system uses **Rancher Fleet** for GitOps-style deployments:

**Status: ✅ IMPLEMENTED** (pending chart hashes)

The complete Fleet-based deployment pipeline is implemented:

- ✓ Module structure (Platform/Project/Target layers)
- ✓ Batch and bundle definitions
- ✓ Wookie project with Istio component
- ✓ Local k3d target configuration
- ✓ `kubelib` for Helm chart fetching and rendering
- ✓ `fleetlib` for Fleet bundle generation
- ✓ Automated deployment script

**What's needed to use it:**
1. Fill in chart hashes in `pkgs/charts/charts.nix` (run `./scripts/fetch-chart-hashes.sh`)
2. Install Fleet on your cluster
3. Run `nix run .#deploy-fleet`

### 3. Clean Up

```bash
nix run .#delete-cluster
```

## Development

Enter the dev shell to get all tools:

```bash
nix develop

# Available tools:
# - k3d
# - kubectl
# - helm
# - istioctl
```

## Deployment Architecture

### Fleet vs Direct kubectl

This system is designed to support **multiple deployment methods**:

1. **Direct kubectl** (simplest, for dev)
   - Build manifests with Nix
   - Apply directly to cluster with kubectl

2. **Fleet** (GitOps, for production)
   - Generate Fleet Bundle resources
   - Fleet controller watches git repo
   - Automatic deployment and drift detection

3. **Helmfile** (alternative to Fleet)
   - Generate Helmfile configuration
   - Use `helmfile sync` to deploy

**Current Implementation:** None of these are implemented yet. The module system generates the configuration tree, but the output renderers need to be built.

### Planned Output Structure

```
result/
├── kubectl/           # Direct kubectl deployment
│   ├── crds/
│   ├── namespaces/
│   ├── operators/
│   └── services/
├── fleet/             # Fleet bundles
│   └── bundles/
│       ├── istio-base.yaml
│       ├── istiod.yaml
│       └── ...
└── helmfile/          # Helmfile configuration
    └── helmfile.yaml
```

## How It Works

### Module System

The module system follows NixOS conventions with three layers:

1. **Platform** (`modules/platform/`): Defines HOW to deploy
   - Batch-based deployment system with priorities
   - Bundle abstraction for Helm charts and manifests

2. **Projects** (`modules/projects/`): Defines WHAT to deploy
   - **Wookie** - Main project containing:
     - Istio service mesh (multi-cluster)
     - PXC (Percona XtraDB Cluster) - future
     - Monitoring, backup, etc. - future

3. **Targets** (`modules/targets/`): Defines WHERE to deploy
   - Local k3d for development
   - Future: staging, production, DR

### Example Configuration

```nix
{
  # WHERE to deploy (target)
  targets.local-k3d = {
    enable = true;
    clusterName = "wookie-local";
  };

  # WHAT to deploy (project with components)
  projects.wookie = {
    enable = true;
    clusterRole = "standalone";
    
    # Istio component
    istio = {
      enable = true;
      version = "1_24_2";
    };
    
    # PXC component (future)
    # pxc.enable = true;
  };
}
```

This configuration:
1. Creates deployment batches (CRDs → Namespaces → Operators → Services)
2. Populates batches with Wookie project bundles (Istio components)
3. Generates cluster creation scripts

### Batches and Priorities

Deployments are organized into batches with priorities:

- **CRDs** (priority 100): Custom Resource Definitions
- **Namespaces** (priority 200): Kubernetes namespaces
- **Operators** (priority 300): Controllers and operators
- **Services** (priority 600): Application services

Higher priority = deploys first.

### Bundles

Each bundle contains:
- Helm chart reference with values
- Or raw Kubernetes manifests
- Dependencies on other bundles
- Namespace assignment

## Adding a New Project

1. Create `modules/projects/my-project/default.nix`
2. Define options for your project
3. Populate `platform.kubernetes.cluster.batches` with bundles
4. Add required charts to `pkgs/charts/charts.nix`

## Adding a New Target

1. Create `modules/targets/my-target.nix`
2. Define target-specific options (cluster name, size, etc.)
3. Set `platform.kubernetes.cluster.uniqueIdentifier`
4. Generate any target-specific scripts via `build.scripts`

## Current Implementation Status

### ✅ Completed
- Module structure and organization
- Wookie project module with Istio component
- Local k3d target module
- Chart catalog structure (istio-base, istiod, istio-gateway)
- k3d cluster creation/deletion scripts
- **`kubelib`** for Helm chart fetching and rendering
- **`fleetlib`** for Fleet bundle generation
- **Fleet bundle packages** in flake.nix
- **Deployment automation** via `deploy-fleet` script

### ⚠️ Required User Action
**Chart hash values** - Nix will tell you the correct hashes:

```bash
# Try to build (it will fail with the correct hash in the error message)
nix build .#fleet-bundles

# Copy the "got: sha256-XXXXX..." hash from each error
# Update pkgs/charts/charts.nix with the hash
# Repeat for all 3 charts (base, istiod, gateway)
```

### ❌ Not Yet Implemented (Future)
- Multi-cluster target examples
- PXC (Percona XtraDB Cluster) project module
- Monitoring module (Prometheus/Grafana)
- Backup module
- Certificate management helpers

## Available Nix Commands

```bash
# Cluster management
nix run .#create-cluster    # Create k3d cluster
nix run .#delete-cluster    # Delete k3d cluster

# Build Fleet bundles
nix build .#fleet-bundles           # All bundles
nix build .#fleet-bundle-crds       # Just CRDs
nix build .#fleet-bundle-namespaces # Just namespaces
nix build .#fleet-bundle-operators  # Just operators (Istiod)
nix build .#fleet-bundle-services   # Just services

# Deploy
nix run .#deploy-fleet      # Deploy all Fleet bundles to cluster

# Development
nix develop                 # Enter dev shell with all tools
```

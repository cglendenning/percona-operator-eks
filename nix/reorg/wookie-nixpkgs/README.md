# Wookie NixPkgs

A NixOS-style module system for declarative Kubernetes deployments.

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

### 1. Create a Local k3d Cluster with Wookie (Istio + PXC)

```bash
cd /Users/craig/percona_operator/nix/reorg/wookie-nixpkgs

# Create the k3d cluster
nix run .#create-cluster

# Verify cluster is running
kubectl cluster-info --context k3d-wookie-local
```

### 2. Deploy Wookie Project

```bash
# TODO: Generate and apply manifests
# This will be implemented once the bundle rendering is complete
```

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

## Status

### Completed
- Module structure and organization
- Wookie project module with Istio component
- Local k3d target module
- Chart catalog (istio-base, istiod, istio-gateway)

### TODO
- Implement manifest rendering from bundles
- Add Fleet/Helmfile output generation
- Create multi-cluster target examples
- Add PXC (Percona XtraDB Cluster) project module
- Implement certificate management helpers

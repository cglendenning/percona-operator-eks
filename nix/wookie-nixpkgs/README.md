# Wookie NixPkgs

Declarative Kubernetes deployment system using Nix.

## Quick Start

### Single Cluster

```bash
# Stand up the whole stack (create cluster + deploy)
nix run

# Tear it down
nix run .#down
```

### Multi-Cluster

```bash
# Stand up multi-cluster stack
nix run .#up-multi

# Test cross-cluster connectivity
nix run .#test-multi-cluster

# Tear it down
nix run .#down-multi
```

For detailed multi-cluster architecture, see [MULTI_CLUSTER.md](./MULTI_CLUSTER.md).

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
├── targets/              # Deployment targets (local-k3d, multi-cluster-k3d)
└── profiles/             # Complete environment configurations
    ├── local-dev.nix     # Single-cluster local development
    ├── multi-primary.nix # Multi-cluster primary
    └── multi-dr.nix      # Multi-cluster DR
```

Deployment uses helmfile to orchestrate Helm releases with proper dependency ordering.

## Configuration

Profiles are complete environment configurations that compose platform + projects + targets.
Edit profiles in `modules/profiles/` to customize:

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

## Commands

```bash
# Single cluster
nix run              # Stand up (create + deploy)
nix run .#down       # Tear down

# Multi-cluster
nix run .#up-multi   # Stand up both clusters
nix run .#down-multi # Tear down both clusters
nix run .#test       # Test cross-cluster connectivity

# Build outputs
nix build .#manifests          # Raw Kubernetes manifests
nix build .#helmfile           # Helmfile configuration
nix build .#manifests-cluster-a
nix build .#manifests-cluster-b
nix build .#helmfile-cluster-a
nix build .#helmfile-cluster-b
```

Advanced granular operations are available as packages (use `nix build .#<name>`):
`deploy`, `diff`, `destroy`, `create-cluster`, `delete-cluster`, `deploy-cluster-a`, `deploy-cluster-b`, etc.

### Development
```bash
nix develop                    # Dev shell with tools
```

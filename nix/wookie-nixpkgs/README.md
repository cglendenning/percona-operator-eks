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

### SeaweedFS Replication

Deploy SeaweedFS with active-passive replication between two filers:

```bash
# Stand up SeaweedFS with replication
nix run .#seaweedfs-repl-up

# Check sync status
kubectl logs -n seaweedfs-primary -l sync-pair=primary-to-secondary

# Test replication
kubectl exec -n seaweedfs-primary deployment/seaweedfs-filer -- sh -c 'echo test > /data/test.txt'
kubectl exec -n seaweedfs-secondary deployment/seaweedfs-filer -- cat /data/test.txt

# Tear down
nix run .#seaweedfs-repl-down
```

### Development
```bash
nix develop                    # Dev shell with tools
```

## SeaweedFS Filer Sync Configuration

The `platform.seaweedfs.filerSync` module enables active-passive or active-active cross-cluster filer synchronization using the `weed filer.sync` command.

### Configuration Options

```nix
platform.seaweedfs.filerSync = {
  enable = true;
  syncPairs = [
    {
      name = "primary-to-secondary";
      namespace = "seaweedfs-primary";
      activePassive = true;  # false for active-active bi-directional sync
      
      filerA = {
        host = "seaweedfs-filer.seaweedfs-primary.svc.cluster.local";
        port = 8888;
        path = null;  # Sync all paths, or specify "/specific/path"
        useFilerProxy = false;  # true to route through filer instead of volume servers
        debug = false;  # true for detailed transfer logging
      };
      
      filerB = {
        host = "seaweedfs-filer.seaweedfs-secondary.svc.cluster.local";
        port = 8888;
        path = null;
        useFilerProxy = false;
        debug = false;
      };
      
      image = "chrislusf/seaweedfs:latest";
      
      resources = {
        requests = { cpu = "100m"; memory = "128Mi"; };
        limits = { cpu = "500m"; memory = "512Mi"; };
      };
    }
  ];
};
```

### Key Points

- **Active-Passive**: Only run in ONE cluster. Changes replicate from filerA to filerB.
- **Active-Active**: Run in both directions if needed (requires two sync pairs).
- **Cross-Cluster**: Use full DNS names or external IPs when syncing across clusters.
- **Path Filtering**: Sync specific paths with `-a.path` and `-b.path` options.
- **Filer Proxy**: Enable when volume server IPs are not accessible from sync pod.

### Example: Cross-Cluster Active-Passive

```nix
platform.seaweedfs.filerSync = {
  enable = true;
  syncPairs = [{
    name = "cluster-a-to-cluster-b";
    namespace = "sync-jobs";
    activePassive = true;
    
    filerA = {
      host = "filer.cluster-a.example.com";
      port = 8888;
      useFilerProxy = true;  # Required when crossing networks
    };
    
    filerB = {
      host = "filer.cluster-b.example.com";
      port = 8888;
      useFilerProxy = true;
    };
  }];
};
```

See the [SeaweedFS documentation](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization) for more details on filer sync topologies and limitations.

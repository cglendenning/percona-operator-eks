# SeaweedFS Platform Module

Provides platform-level configuration for SeaweedFS filer synchronization.

## Module: filer-sync.nix

Enables active-passive or active-active cross-cluster filer synchronization using the `weed filer.sync` command.

### Overview

The filer sync module creates a Kubernetes Deployment that runs `weed filer.sync` to continuously replicate metadata and file changes between two SeaweedFS filers. This enables:

- **Active-Passive Replication**: One-way replication from primary to secondary filer
- **Active-Active Replication**: Bi-directional replication (requires two sync pairs)
- **Path-Specific Sync**: Replicate only specific directories
- **Cross-Cluster Support**: Sync between filers in different Kubernetes clusters or networks

### Usage

```nix
platform.seaweedfs.filerSync = {
  enable = true;
  syncPairs = [
    {
      name = "primary-to-secondary";
      namespace = "seaweedfs";
      activePassive = true;
      
      filerA = {
        host = "seaweedfs-filer.primary.svc.cluster.local";
        port = 8888;
      };
      
      filerB = {
        host = "seaweedfs-filer.secondary.svc.cluster.local";
        port = 8888;
      };
    }
  ];
};
```

### Configuration Options

- `enable`: Enable the filer sync module
- `syncPairs`: List of sync configurations. Each creates a separate Deployment.

#### Sync Pair Options

- `name`: Deployment name (e.g., "primary-to-secondary")
- `namespace`: Kubernetes namespace for the sync Deployment
- `activePassive`: `true` for one-way sync (A→B), `false` for active-active
- `filerA`: Source filer configuration
- `filerB`: Destination filer configuration
- `image`: SeaweedFS container image (default: "chrislusf/seaweedfs:latest")
- `resources`: Kubernetes resource requests/limits
- `extraEnv`: Additional environment variables

#### Filer Configuration (filerA/filerB)

- `host`: Filer hostname or service DNS name
- `port`: Filer port (default: 8888)
- `path`: Sync only this path (null = sync all paths)
- `useFilerProxy`: Route data through filer instead of volume servers (needed for cross-network sync)
- `debug`: Enable detailed transfer logging

### Important Notes

1. **Active-Passive**: Only run sync in ONE location. The sync process reads from filerA and writes to filerB.

2. **Active-Active**: Create TWO sync pairs (A→B and B→A) if you need bi-directional sync.

3. **Cross-Cluster**: Set `useFilerProxy = true` when syncing across networks where volume server IPs are not accessible.

4. **Network Bandwidth**: Sync is limited by network bandwidth and latency. For high-change-rate clusters, consider syncing only specific paths.

5. **Checkpointing**: The sync process automatically persists checkpoints and can be safely stopped/restarted.

### Examples

#### Active-Passive Local Sync

```nix
platform.seaweedfs.filerSync = {
  enable = true;
  syncPairs = [{
    name = "primary-to-secondary";
    namespace = "seaweedfs";
    activePassive = true;
    filerA.host = "seaweedfs-filer.primary.svc.cluster.local";
    filerB.host = "seaweedfs-filer.secondary.svc.cluster.local";
  }];
};
```

#### Cross-Cluster with Filer Proxy

```nix
platform.seaweedfs.filerSync = {
  enable = true;
  syncPairs = [{
    name = "datacenter-a-to-b";
    namespace = "sync-jobs";
    activePassive = true;
    
    filerA = {
      host = "filer.dc-a.example.com";
      port = 8888;
      useFilerProxy = true;
    };
    
    filerB = {
      host = "filer.dc-b.example.com";
      port = 8888;
      useFilerProxy = true;
    };
  }];
};
```

#### Path-Specific Sync

```nix
platform.seaweedfs.filerSync = {
  enable = true;
  syncPairs = [{
    name = "backup-critical-data";
    namespace = "seaweedfs";
    activePassive = true;
    
    filerA = {
      host = "seaweedfs-filer.primary.svc.cluster.local";
      path = "/data/critical";
    };
    
    filerB = {
      host = "seaweedfs-filer.backup.svc.cluster.local";
      path = "/backup/critical";
    };
  }];
};
```

### Monitoring

Check sync status using kubectl:

```bash
# View sync logs
kubectl logs -n <namespace> -l sync-pair=<name> -f

# Check sync pod status
kubectl get pods -n <namespace> -l app=seaweedfs-filer-sync

# View sync deployment
kubectl describe deployment <name> -n <namespace>
```

### References

- [SeaweedFS Filer Active-Active Documentation](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization)
- [Async Replication to Another Filer](https://github.com/seaweedfs/seaweedfs/wiki/Async-Replication-to-another-Filer)

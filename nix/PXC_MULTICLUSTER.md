# Percona XtraDB Cluster (PXC) Cross-Cluster Replication with Istio

This guide shows how to use Istio service mesh for PXC async replication between k3d clusters without exposing external IPs.

## Why Istio for PXC?

**Without Istio:**
- Need `pxc.expose = true` to create external LoadBalancer IPs
- Reference pods by IP address (brittle, changes on restart)
- Manual IP management

**With Istio:**
- Reference services by stable DNS names
- No external IPs needed
- Automatic service discovery
- mTLS between clusters (optional)

## Architecture

```
┌─────────────────────┐         ┌─────────────────────┐
│   Cluster A (k3d)   │         │   Cluster B (k3d)   │
│                     │         │                     │
│  ┌──────────────┐   │         │   ┌──────────────┐  │
│  │ PXC Primary  │   │         │   │ PXC Replica  │  │
│  │   (Source)   │   │         │   │   (Target)   │  │
│  └──────┬───────┘   │         │   └───────▲──────┘  │
│         │           │         │           │         │
│    ┌────▼────┐      │         │      ┌────┴─────┐   │
│    │ Istiod  │      │         │      │  Istiod  │   │
│    └─────────┘      │         │      └──────────┘   │
└─────────────────────┘         └─────────────────────┘
          │                               ▲
          │   ServiceEntry defines        │
          │   pxc-source.cluster-b.global │
          └───────────────────────────────┘
                  MySQL Replication
```

## Three Approaches

### 1. ServiceEntry (Manual, Simple)
Define remote services explicitly. Good for 2-3 clusters.

### 2. Multicluster Mesh (Automatic, Complex)
Istio automatically discovers services across clusters. Good for many clusters.

### 3. Hybrid
ServiceEntry for static endpoints + multicluster for dynamic discovery.

---

## Approach 1: ServiceEntry (Recommended for PXC)

### Prerequisites

1. Two k3d clusters with Istio installed
2. PXC deployed in both clusters
3. Network connectivity between cluster nodes

### Step 1: Deploy Istio on Both Clusters

**Cluster A (source):**
```bash
# Create cluster
cd nix
nix run .#create-cluster

# Deploy Istio
nix build
./result/deploy.sh

# Verify
kubectl get pods -n istio-system
```

**Cluster B (target):**
```bash
# Create second cluster with different name
export KUBECONFIG=~/.kube/config-cluster-b

# Edit flake.nix to change cluster name
sed -i '' 's/clusterName = "local"/clusterName = "cluster-b"/' flake.nix

# Create and deploy
nix run .#create-cluster
nix build
./result/deploy.sh
```

### Step 2: Deploy PXC Without External IPs

**On both clusters**, deploy PXC with sidecar injection:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pxc
  labels:
    istio-injection: enabled  # Enable sidecar injection

---
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBCluster
metadata:
  name: pxc-cluster
  namespace: pxc
spec:
  crVersion: 1.13.0
  secretsName: pxc-secrets
  
  # NO pxc.expose needed!
  pxc:
    size: 3
    image: percona/percona-xtradb-cluster:8.0.32-24.2
    resources:
      requests:
        memory: 1G
        cpu: 600m
    affinity:
      antiAffinityTopologyKey: "kubernetes.io/hostname"
```

### Step 3: Create ServiceEntry for Remote Cluster

**In Cluster A** (to access Cluster B's PXC):

Create `pxc-remote.nix`:

```nix
# Add to your flake.nix packages
pxc-cluster-b = serviceEntryLib.mkPXCServiceEntry {
  name = "pxc-cluster";
  namespace = "pxc";
  remoteClusterName = "cluster-b";
  remoteEndpoints = [
    # Get these IPs from: kubectl get nodes -o wide (in cluster B)
    { address = "172.19.0.2"; port = 3306; }
    { address = "172.19.0.3"; port = 3306; }
    { address = "172.19.0.4"; port = 3306; }
  ];
};
```

Build and apply:

```bash
nix build .#pxc-cluster-b
kubectl apply -f result/manifest.yaml
```

### Step 4: Configure Async Replication

Now you can use DNS names instead of IPs!

**On Cluster A, connect to PXC pod:**

```bash
kubectl exec -it pxc-cluster-pxc-0 -n pxc -c pxc -- mysql -uroot -p

# Set up replication channel
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='pxc-cluster.cluster-b.global',
  SOURCE_PORT=3306,
  SOURCE_USER='replication_user',
  SOURCE_PASSWORD='password',
  SOURCE_AUTO_POSITION=1
  FOR CHANNEL 'cluster_b_source';

START REPLICA FOR CHANNEL 'cluster_b_source';

SHOW REPLICA STATUS FOR CHANNEL 'cluster_b_source'\G
```

### Step 5: Verify Service Resolution

```bash
# From Cluster A, test DNS resolution
kubectl run -it --rm debug --image=nicolaka/netshoot -n pxc -- bash

# Inside debug pod
nslookup pxc-cluster.cluster-b.global
# Should resolve to 240.0.0.X virtual IP

# Test MySQL connection
mysql -h pxc-cluster.cluster-b.global -u root -p
```

---

## Approach 2: Multicluster Mesh (Automatic Discovery)

### Architecture

Istio discovers services automatically across clusters via a shared control plane or east-west gateway.

### Step 1: Deploy Istio with Multicluster Config

Edit your `flake.nix` to add multicluster support:

```nix
# In packages
istio-multicluster-a = serviceEntryLib.mkMulticlusterConfig {
  clusterName = "cluster-a";
  network = "network1";
  meshId = "mesh1";
};

istio-multicluster-b = serviceEntryLib.mkMulticlusterConfig {
  clusterName = "cluster-b";
  network = "network1";
  meshId = "mesh1";
};
```

Build and apply to each cluster:

```bash
# Cluster A
kubectl config use-context k3d-local
nix build .#istio-multicluster-a
kubectl apply -f result/manifest.yaml

# Cluster B
kubectl config use-context k3d-cluster-b
nix build .#istio-multicluster-b
kubectl apply -f result/manifest.yaml
```

### Step 2: Create Remote Secrets

Exchange kubeconfig secrets so each Istiod can discover the other cluster:

```bash
# Create remote secret for Cluster B in Cluster A
istioctl create-remote-secret \
  --context=k3d-cluster-b \
  --name=cluster-b | \
  kubectl apply -f - --context=k3d-local

# Create remote secret for Cluster A in Cluster B
istioctl create-remote-secret \
  --context=k3d-local \
  --name=cluster-a | \
  kubectl apply -f - --context=k3d-cluster-b
```

### Step 3: Verify Cross-Cluster Discovery

Services are now automatically discoverable!

```bash
# From Cluster A
kubectl exec -it pxc-cluster-pxc-0 -n pxc -c pxc -- bash

# Services from Cluster B are available as:
# <service>.<namespace>.svc.cluster.local (still works locally)
# <service>.<namespace>.svc.cluster-b.global (cross-cluster)

mysql -h pxc-cluster-haproxy.pxc.svc.cluster-b.global -u root -p
```

### Step 4: Configure PXC Replication

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='pxc-cluster-haproxy.pxc.svc.cluster-b.global',
  SOURCE_PORT=3306,
  SOURCE_USER='replication_user',
  SOURCE_PASSWORD='password',
  SOURCE_AUTO_POSITION=1
  FOR CHANNEL 'cluster_b_source';

START REPLICA FOR CHANNEL 'cluster_b_source';
```

---

## Approach 3: Hybrid (Best of Both)

Use ServiceEntry for critical, static services (like primary PXC) and multicluster for dynamic discovery.

```nix
# Critical replication source - use ServiceEntry
pxc-primary = serviceEntryLib.mkPXCServiceEntry {
  name = "pxc-primary";
  namespace = "pxc";
  remoteClusterName = "production";
  remoteEndpoints = [
    { address = "10.0.1.10"; port = 3306; }
  ];
};

# Other services - use multicluster auto-discovery
istio-multicluster = serviceEntryLib.mkMulticlusterConfig {
  clusterName = "staging";
  network = "network1";
  meshId = "mesh1";
};
```

---

## Comparison

| Feature | ServiceEntry | Multicluster | Hybrid |
|---------|-------------|--------------|--------|
| Setup Complexity | Low | High | Medium |
| Automatic Discovery | No | Yes | Partial |
| Control | Full | Less | Balanced |
| Best For | 2-3 clusters | Many clusters | Production |
| IP Changes | Manual update | Automatic | Mixed |
| Nix-Friendly | ✓✓✓ | ✓✓ | ✓✓✓ |

---

## Complete Example: Two k3d Clusters

### Setup Script

```bash
#!/usr/bin/env bash
set -euo pipefail

cd nix

# Create Cluster A
echo "Creating Cluster A..."
nix run .#create-cluster
nix build
./result/deploy.sh

# Save kubeconfig
kubectl config view --raw > ~/.kube/config-cluster-a

# Create Cluster B
echo "Creating Cluster B..."
# Edit cluster name in flake
sed -i '' 's/clusterName = "local"/clusterName = "cluster-b"/' flake.nix
sed -i '' 's/name ? "local"/name ? "cluster-b"/' modules/k3d/default.nix

# Use different ports
sed -i '' 's/port = "80:80"/port = "8080:80"/' flake.nix
sed -i '' 's/port = "443:443"/port = "8443:443"/' flake.nix

nix run .#create-cluster
nix build
./result/deploy.sh

kubectl config view --raw > ~/.kube/config-cluster-b

# Restore original
git checkout flake.nix modules/k3d/default.nix

echo "Both clusters ready!"
echo "Cluster A: k3d-local"
echo "Cluster B: k3d-cluster-b"
```

### Deploy PXC with ServiceEntry

```nix
# flake.nix additions
packages = forAllSystems (system:
  let
    # ... existing code ...
  in
  {
    # ... existing packages ...
    
    # ServiceEntry for Cluster B's PXC
    pxc-cluster-b-entry = serviceEntryLib.mkPXCServiceEntry {
      name = "pxc-cluster";
      namespace = "pxc";
      remoteClusterName = "cluster-b";
      remoteEndpoints = [
        { address = "172.19.0.2"; }
        { address = "172.19.0.3"; }
        { address = "172.19.0.4"; }
      ];
    };
  }
);
```

Deploy:

```bash
# Build ServiceEntry
nix build .#pxc-cluster-b-entry

# Apply to Cluster A
kubectl --context=k3d-local apply -f result/manifest.yaml

# Now configure replication from Cluster A to use:
# pxc-cluster.cluster-b.global:3306
```

---

## Benefits for PXC

1. **No External IPs** - Remove `pxc.expose = true` from both clusters
2. **Stable DNS Names** - `pxc-cluster.cluster-b.global` never changes
3. **Pod Restarts** - Replication continues even if pods restart with new IPs
4. **Load Balancing** - Istio can load balance across multiple endpoints
5. **mTLS** - Optional encryption between clusters
6. **Observability** - Istio metrics for replication traffic
7. **Declarative** - Everything in Nix, version controlled

---

## Troubleshooting

### ServiceEntry Not Resolving

```bash
# Check ServiceEntry
kubectl get serviceentry -A

# Check if DNS works
kubectl run -it debug --image=busybox -n pxc -- nslookup pxc-cluster.cluster-b.global

# Check Envoy config
kubectl exec -n pxc pxc-cluster-pxc-0 -c istio-proxy -- \
  curl localhost:15000/clusters | grep cluster-b
```

### Replication Not Connecting

```bash
# Check if Istio sidecar is injected
kubectl get pod pxc-cluster-pxc-0 -n pxc -o jsonpath='{.spec.containers[*].name}'
# Should show: pxc, istio-proxy

# Check sidecar logs
kubectl logs -n pxc pxc-cluster-pxc-0 -c istio-proxy

# Test connectivity
kubectl exec -n pxc pxc-cluster-pxc-0 -c pxc -- \
  nc -zv pxc-cluster.cluster-b.global 3306
```

### No Sidecar Injection

```bash
# Check namespace label
kubectl get namespace pxc --show-labels

# Add injection label
kubectl label namespace pxc istio-injection=enabled

# Restart pods
kubectl rollout restart statefulset pxc-cluster-pxc -n pxc
```

---

## Next Steps

1. Test failover scenarios
2. Add monitoring with Prometheus
3. Configure mTLS for replication traffic
4. Set up GitOps with Fleet
5. Add more clusters to the mesh

---

## References

- [Istio Multicluster](https://istio.io/latest/docs/setup/install/multicluster/)
- [ServiceEntry Documentation](https://istio.io/latest/docs/reference/config/networking/service-entry/)
- [Percona XtraDB Cluster Async Replication](https://docs.percona.com/percona-xtradb-cluster/8.0/howtos/async-replication.html)

# Cross-Cluster Service Discovery Demo

Demonstrates Istio ServiceEntry for cross-cluster communication - same approach used for PXC async replication.

## What This Shows

- Cluster A runs a "hello" service
- Cluster B accesses it via DNS name `hello.cluster-a.global`
- No external IPs or LoadBalancers needed
- Same pattern works for PXC replication

## Setup

### 1. Create Two Clusters

```bash
cd demo
chmod +x *.sh
./setup-clusters.sh
```

This creates:
- `cluster-a` (ports 8080/8443)
- `cluster-b` (ports 9080/9443)

### 2. Build Istio Manifests

```bash
cd ..
nix build
```

### 3. Deploy Istio and Hello Service

```bash
cd demo
./deploy.sh
```

This:
- Deploys Istio to both clusters
- Deploys hello service to cluster-a
- Shows cluster-a node IPs

### 4. Update ServiceEntry with Node IPs

The deploy script shows cluster-a node IPs. Update `../flake.nix`:

```nix
hello-remote = serviceEntryLib.mkServiceEntry {
  # ...
  endpoints = [
    { address = "<IP-from-deploy-output>"; ports = { http = 8080; }; }
    { address = "<IP-from-deploy-output>"; ports = { http = 8080; }; }
    { address = "<IP-from-deploy-output>"; ports = { http = 8080; }; }
  ];
};
```

Or get them manually:

```bash
kubectl get nodes -o wide --context k3d-cluster-a
# Use INTERNAL-IP column
```

### 5. Build and Deploy ServiceEntry

```bash
cd ..
nix build .#hello-remote
kubectl apply -f result/manifest.yaml --context k3d-cluster-b
```

### 6. Test Cross-Cluster Access

```bash
cd demo
./test.sh
```

## Expected Output

```
1. Testing from Cluster A (local):
Hello from Cluster A!

2. Testing from Cluster B (remote via Istio ServiceEntry):
Hello from Cluster A!
```

Both should return the same message, proving cluster-b can reach cluster-a's service by DNS name.

## What's Happening

### In Cluster A

```
┌─────────────────────────────┐
│ Cluster A (k3d-cluster-a)   │
│                             │
│  ┌──────────────────────┐   │
│  │ hello deployment     │   │
│  │ + istio-proxy sidecar│   │
│  │                      │   │
│  │ hello.demo.svc:8080  │   │
│  └──────────────────────┘   │
│                             │
│  ┌──────────────────────┐   │
│  │ istiod (control plane│   │
│  └──────────────────────┘   │
└─────────────────────────────┘
       Node IPs: 172.19.0.X
```

### In Cluster B

```
┌─────────────────────────────────────────────┐
│ Cluster B (k3d-cluster-b)                   │
│                                             │
│  ┌──────────────────────────────────────┐   │
│  │ ServiceEntry                         │   │
│  │ hello.cluster-a.global -> 240.0.0.1  │   │
│  │   endpoints: 172.19.0.2:8080         │   │
│  │              172.19.0.3:8080         │   │
│  │              172.19.0.4:8080         │   │
│  └──────────────────────────────────────┘   │
│                                             │
│  ┌──────────────────────────────────────┐   │
│  │ curl pod                             │   │
│  │ + istio-proxy sidecar                │   │
│  │                                      │   │
│  │ curl hello.cluster-a.global:8080    │   │
│  └──────────────────────────────────────┘   │
│           ↓                                 │
│     (Istio resolves to 172.19.0.X:8080)    │
└─────────────────────────────────────────────┘
```

The ServiceEntry tells Istio: "When you see `hello.cluster-a.global`, route to these IPs."

## For PXC Replication

Same pattern, just different values:

```nix
pxc-remote = serviceEntryLib.mkPXCServiceEntry {
  name = "pxc-source";
  namespace = "pxc";
  remoteClusterName = "production";
  remoteEndpoints = [
    { address = "172.19.0.2"; port = 3306; }
  ];
};
```

Then in PXC:

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='pxc-source.production.global',
  SOURCE_PORT=3306,
  SOURCE_USER='repl_user',
  SOURCE_PASSWORD='password';
```

## Manual Testing

### Check DNS Resolution

```bash
kubectl exec -it -n demo <pod-name> -c istio-proxy --context k3d-cluster-b \
  -- curl localhost:15000/clusters | grep hello
```

Should show the cluster-a endpoints.

### Check Service Entry

```bash
kubectl get serviceentry -A --context k3d-cluster-b
kubectl describe serviceentry hello-cluster-a -n demo --context k3d-cluster-b
```

### Direct Connection Test

```bash
# From cluster-b, test direct IP connection
kubectl run -it --rm debug --image=curlimages/curl --context k3d-cluster-b -n demo \
  -- curl -s http://172.19.0.2:8080
```

If this works but the ServiceEntry doesn't, check Istio sidecar injection:

```bash
kubectl get pod -n demo --context k3d-cluster-b -o jsonpath='{.items[0].spec.containers[*].name}'
# Should show: curl istio-proxy
```

## Cleanup

```bash
k3d cluster delete cluster-a
k3d cluster delete cluster-b
```

## Key Takeaways

1. **ServiceEntry** creates DNS entries for external services
2. **No external IPs** needed - uses node IPs directly
3. **Istio sidecar** handles routing and service discovery
4. **Same pattern** works for any TCP service (HTTP, MySQL, PostgreSQL, etc.)
5. **Declarative** - defined in Nix, version controlled

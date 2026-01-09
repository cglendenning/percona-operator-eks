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

### 4. Build and Deploy ServiceEntry

```bash
cd ..
nix build .#hello-remote
kubectl apply -f result/manifest.yaml --context k3d-cluster-b
```

### 5. Test Cross-Cluster Access

```bash
cd demo
./test.sh
```

## Expected Output

```
1. Testing from Cluster A (local - each pod):
Hello from hello-0 in Cluster A!
Hello from hello-1 in Cluster A!
Hello from hello-2 in Cluster A!

2. Testing from Cluster B (remote via Istio ServiceEntry - each pod):
Hello from hello-0 in Cluster A!
Hello from hello-1 in Cluster A!
Hello from hello-2 in Cluster A!
```

Each pod name resolves to the correct pod, proving you can target specific pods by name across clusters.

## What's Happening

### In Cluster A

```
┌─────────────────────────────────────┐
│ Cluster A (k3d-cluster-a)           │
│                                     │
│  StatefulSet: hello                 │
│  ┌───────────────────────────────┐  │
│  │ hello-0.hello.demo.svc:8080   │  │
│  │ + istio-proxy sidecar         │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ hello-1.hello.demo.svc:8080   │  │
│  │ + istio-proxy sidecar         │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ hello-2.hello.demo.svc:8080   │  │
│  │ + istio-proxy sidecar         │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌──────────────────────┐           │
│  │ istiod (control plane│           │
│  └──────────────────────┘           │
└─────────────────────────────────────┘
```

### In Cluster B

```
┌──────────────────────────────────────────────────────┐
│ Cluster B (k3d-cluster-b)                            │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │ ServiceEntry (DNS resolution)                  │  │
│  │ hello-0.cluster-a.global ->                    │  │
│  │   hello-0.hello.demo.svc.cluster.local         │  │
│  │ hello-1.cluster-a.global ->                    │  │
│  │   hello-1.hello.demo.svc.cluster.local         │  │
│  │ hello-2.cluster-a.global ->                    │  │
│  │   hello-2.hello.demo.svc.cluster.local         │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │ curl pod                                       │  │
│  │ + istio-proxy sidecar                          │  │
│  │                                                │  │
│  │ curl hello-0.cluster-a.global:8080            │  │
│  └────────────────────────────────────────────────┘  │
│           ↓                                          │
│     (Istio resolves DNS name, routes to cluster-a)  │
└──────────────────────────────────────────────────────┘
```

The ServiceEntry tells Istio: "When you see `hello-X.cluster-a.global`, resolve it via DNS to `hello-X.hello.demo.svc.cluster.local`."

## For PXC Replication

Same pattern, using DNS names:

```nix
pxc-remote = serviceEntryLib.mkServiceEntry {
  name = "pxc-production";
  namespace = "pxc";
  hosts = [
    "pxc-cluster-pxc-0.production.global"
    "pxc-cluster-pxc-1.production.global"
    "pxc-cluster-pxc-2.production.global"
  ];
  ports = [{
    number = 3306;
    name = "mysql";
    protocol = "TCP";
  }];
  location = "MESH_EXTERNAL";
  resolution = "DNS";
  endpoints = [
    { address = "pxc-cluster-pxc-0.pxc-cluster-pxc.pxc.svc.cluster.local"; }
    { address = "pxc-cluster-pxc-1.pxc-cluster-pxc.pxc.svc.cluster.local"; }
    { address = "pxc-cluster-pxc-2.pxc-cluster-pxc.pxc.svc.cluster.local"; }
  ];
};
```

Then in PXC, reference by name:

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='pxc-cluster-pxc-0.production.global',
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
./cleanup.sh
```

Or manually:

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

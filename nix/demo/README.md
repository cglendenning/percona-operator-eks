# Cross-Cluster Service Discovery Demo

Demonstrates Istio-based cross-cluster communication for PXC async replication across data centers.

## Architecture

```
Cluster A (Source)                 Cluster B (Replica)
┌────────────────────┐            ┌────────────────────┐
│ Istio + mTLS       │            │ Istio + mTLS       │
│                    │            │                    │
│ East-West Gateway  │◄───────────│ ServiceEntry:      │
│ 172.21.0.X:15443   │  Shared    │ src-hello-0 →      │
│   ↓                │  Network   │   via gateway      │
│ hello-0,1,2 pods   │  (VPN)     │                    │
│                    │            │ db-pxc-0,1,2       │
│                    │            │ (local replica)    │
└────────────────────┘            └────────────────────┘
```

**Key Features:**
- DNS-only routing (no IP addresses in config)
- mTLS encryption via east-west gateway
- Explicit ServiceEntry (predictable, debuggable)
- Shared root CA for trust
- Simulates real datacenter VPN connectivity

## Quick Start

```bash
cd demo
chmod +x *.sh

# Create clusters
./setup-clusters.sh

# Deploy simple multi-cluster
./deploy-simple-multicluster.sh

# Test cross-cluster connectivity
./test-simple-multicluster.sh

# Cleanup
./cleanup.sh
```

## What Gets Created

### Cluster A (Source)
- Istio control plane with shared CA
- East-west gateway (port 15443 for mTLS)
- Hello service (3 pods with sidecars)
- Gateway exposing services for cross-cluster access

### Cluster B (Replica)
- Istio control plane with shared CA
- ServiceEntry resources creating aliases:
  - `src-hello-0.demo.svc.cluster.local` → routes to cluster-a's hello-0
  - `src-hello-1.demo.svc.cluster.local` → routes to cluster-a's hello-1
  - `src-hello-2.demo.svc.cluster.local` → routes to cluster-a's hello-2

### Network
- Shared Docker network (`k3d-interconnect`)
- Simulates VPN/VPC peering between datacenters
- East-west gateway accessible on shared network IP

## How It Works

1. **Shared CA**: Both clusters use same root certificate for mTLS trust
2. **East-West Gateway**: Secure tunnel for cross-cluster traffic (TLS passthrough)
3. **ServiceEntry**: Maps alias names in cluster-b to gateway endpoint
4. **Istio Routing**: Sidecar in cluster-b routes to gateway, which routes to cluster-a service
5. **No IPs**: All configuration uses DNS names and gateway addresses

**Flow:**
```
App in Cluster B
  → curl http://src-hello-0.demo.svc.cluster.local:8080
  → Istio sidecar intercepts (DNS from ServiceEntry)
  → Routes to east-west gateway at 172.21.0.X:15443
  → Gateway forwards to hello-0 in cluster-a
  → mTLS encrypted end-to-end
```

## For PXC Async Replication

### Cluster A (Source)

Deploy PXC normally with Istio sidecars:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db-pxc
  namespace: pxc
spec:
  serviceName: db-pxc
  replicas: 3
  template:
    metadata:
      labels:
        app: pxc
    spec:
      containers:
      - name: pxc
        image: percona/percona-xtradb-cluster:8.0
```

### Cluster B (Replica)

Create ServiceEntry for each source pod:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-db-pxc-0
  namespace: pxc
spec:
  hosts:
  - "src-db-pxc-0.pxc.svc.cluster.local"
  location: MESH_INTERNAL
  ports:
  - number: 3306
    name: mysql
    protocol: TCP
  resolution: STATIC
  endpoints:
  - address: "<east-west-gateway-ip>"
    ports:
      mysql: 15443
```

### PXC Replication Config

```sql
-- In replica cluster, use the alias
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='src-db-pxc-0.pxc.svc.cluster.local',
  SOURCE_PORT=3306,
  SOURCE_USER='repl_user',
  SOURCE_PASSWORD='password';
```

### Benefits

- **No pxc.expose needed**: Services not exposed externally
- **DNS-based**: Reference source pods by name, not IP
- **mTLS encrypted**: All replication traffic secured
- **Stable config**: Pod IPs can change, gateway IP is stable
- **Network policy friendly**: Traffic only via controlled gateway
- **Explicit control**: You define exactly which pods to replicate from

## Comparison to Alternatives

### vs Manual ServiceEntry with NodePorts
- **Better security**: Traffic encrypted via mTLS gateway vs exposed NodePorts
- **Better isolation**: Single gateway point vs multiple NodePort services
- **Production-ready**: Gateway is standard Istio pattern

### vs Full Auto-Discovery Multi-Cluster
- **Simpler**: No remote secrets, no API server cross-access needed
- **More explicit**: You define routes, not automatic
- **Easier debug**: Fewer components, clear traffic path
- **Better for DB**: Databases don't need automatic discovery

## Network Requirements

In production (replacing Docker network):
- **AWS**: VPC peering or Transit Gateway
- **GCP**: VPC Network Peering
- **Azure**: VNet peering
- **On-prem**: IPsec VPN, dedicated fiber, or SD-WAN
- **Hybrid**: AWS Direct Connect, Azure ExpressRoute, GCP Interconnect

The east-west gateway IP must be routable between clusters.

## Troubleshooting

### Check ServiceEntry
```bash
kubectl get serviceentry -n demo --context k3d-cluster-b
kubectl describe serviceentry src-hello-0 -n demo --context k3d-cluster-b
```

### Check East-West Gateway
```bash
kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a
kubectl logs -n istio-system -l istio=eastwestgateway --context k3d-cluster-a --tail=50
```

### Test Direct Gateway Access
```bash
# From cluster-b pod
kubectl exec test-pod -n demo --context k3d-cluster-b -- \
  curl -v http://<gateway-ip>:15443
```

### Check Sidecar Configuration
```bash
kubectl exec test-pod -n demo --context k3d-cluster-b -c istio-proxy -- \
  curl localhost:15000/config_dump | grep src-hello
```

### Verify mTLS Certificates
```bash
kubectl get secret cacerts -n istio-system --context k3d-cluster-a -o yaml
kubectl get secret cacerts -n istio-system --context k3d-cluster-b -o yaml
# root-cert.pem should be identical in both
```

## Files

- `setup-clusters.sh` - Create k3d clusters
- `setup-certs.sh` - Generate shared CA certificates
- `deploy-simple-multicluster.sh` - Deploy Istio + services
- `test-simple-multicluster.sh` - Verify connectivity
- `eastwest-gateway.yaml` - East-west gateway deployment
- `hello-service.yaml` - Demo service (StatefulSet + headless service)
- `cleanup.sh` - Remove everything

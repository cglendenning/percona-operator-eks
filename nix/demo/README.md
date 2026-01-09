# Istio Multi-Cluster for Cross-Datacenter Database Replication

Production-ready Istio setup for PXC async replication across isolated Kubernetes clusters.

## Architecture

```
Datacenter 1 (Cluster A)           Datacenter 2 (Cluster B)
┌──────────────────────┐          ┌──────────────────────┐
│ Namespace: demo      │          │ Namespace: demo-dr   │
│                      │          │                      │
│ Services:            │          │ ServiceEntry:        │
│ - hello-0,1,2        │          │ - Routes to gateway  │
│   (NOT exposed)      │          │                      │
│                      │          │ References by name:  │
│ East-West Gateway    │◄─────────│ hello-X.hello.demo...│
│ (ONLY external IP)   │  mTLS    │                      │
└──────────────────────┘          └──────────────────────┘
```

**Key Points:**
- Clusters are isolated (different networks)
- Only the gateway has an external IP
- Services remain internal (not exposed)
- Different namespaces eliminate need for aliases
- mTLS encryption via gateway

## Quick Start

```bash
cd demo
chmod +x *.sh

./setup-clusters.sh      # Create k3d clusters
./setup-certs.sh         # Generate shared CA
./deploy-production.sh   # Deploy everything
./test-production.sh     # Verify connectivity
./cleanup.sh             # Remove all
```

## What Gets Deployed

### Cluster A (Source/Primary)
- **Namespace**: `demo`
- **Istio**: Control plane + east-west gateway
- **Services**: hello-0, hello-1, hello-2 (internal only)
- **Gateway**: External IP for cross-cluster access

### Cluster B (Replica/DR)
- **Namespace**: `demo-dr` 
- **Istio**: Control plane (no gateway)
- **ServiceEntry**: Maps cluster-a services → gateway endpoint

## How It Works

### 1. Shared Certificate Authority
Both clusters use the same root CA certificate:
- Enables mutual TLS trust
- Encrypted traffic end-to-end
- No certificate errors across clusters

### 2. East-West Gateway
Single point of connectivity:
- Gateway gets external IP (LoadBalancer)
- Services stay on private network
- TLS passthrough with SNI routing
- Scales to many services (one gateway for all)

### 3. ServiceEntry in Cluster B
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: cluster-a-hello-services
  namespace: demo-dr
spec:
  hosts:
  - "hello-0.hello.demo.svc.cluster.local"
  - "hello-1.hello.demo.svc.cluster.local"
  - "hello-2.hello.demo.svc.cluster.local"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "<gateway-ip>"
    ports:
      http: 15443
```

### 4. DNS-Based Access
From cluster-b:
```bash
curl http://hello-0.hello.demo.svc.cluster.local:8080
```

Istio sidecar:
1. Intercepts DNS query
2. Routes to gateway (via ServiceEntry)
3. Gateway forwards to actual service in cluster-a
4. mTLS encrypted throughout

## For PXC Async Replication

### Cluster A (Primary - namespace: wookie)
```yaml
apiVersion: v1
kind: StatefulSet
metadata:
  name: db-pxc
  namespace: wookie
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

Pods: `db-pxc-0.db-pxc.wookie.svc.cluster.local`

### Cluster B (Replica - namespace: wookie-dr)
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: cluster-a-pxc
  namespace: wookie-dr
spec:
  hosts:
  - "db-pxc-0.db-pxc.wookie.svc.cluster.local"
  - "db-pxc-1.db-pxc.wookie.svc.cluster.local"
  - "db-pxc-2.db-pxc.wookie.svc.cluster.local"
  location: MESH_INTERNAL
  ports:
  - number: 3306
    name: mysql
    protocol: TCP
  resolution: STATIC
  endpoints:
  - address: "<gateway-external-ip>"
    ports:
      mysql: 15443
```

### PXC Replication Configuration
```sql
-- In cluster-b replica, use actual DNS name from cluster-a
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='db-pxc-0.db-pxc.wookie.svc.cluster.local',
  SOURCE_PORT=3306,
  SOURCE_USER='repl_user',
  SOURCE_PASSWORD='password';
```

**Benefits:**
- ✅ No `pxc.expose=true` needed
- ✅ No external LoadBalancer per pod
- ✅ DNS names (no IP addresses)
- ✅ mTLS encryption
- ✅ Single gateway for all services
- ✅ Services remain internal

## Why Different Namespaces?

**Same namespace (demo/demo):**
- ❌ DNS collision: Both clusters have `db-pxc-0.db-pxc.demo.svc.cluster.local`
- ❌ Need custom aliases: `src-db-pxc-0`
- ❌ Complex VirtualService routing
- ❌ More configuration

**Different namespaces (wookie/wookie-dr):**
- ✅ No collision: `wookie` vs `wookie-dr` are different
- ✅ Use actual service names
- ✅ Gateway SNI routing works automatically
- ✅ Clearer which is source vs replica

## Network Requirements

### In Production
- VPN, VPC peering, or dedicated connection between datacenters
- East-west gateway must have routable IP between clusters
- Common options:
  - **AWS**: VPC peering, Transit Gateway, or public IP with security groups
  - **GCP**: VPC Network Peering or Cloud VPN
  - **Azure**: VNet peering or VPN Gateway
  - **On-prem**: IPsec VPN, SD-WAN, or dedicated fiber

### In This Demo (k3d)
- k3d LoadBalancer exposes gateway on `host.k3d.internal`
- Clusters on separate Docker networks (isolated)
- Simulates datacenter isolation correctly

## Troubleshooting

### Check Gateway Status
```bash
kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a
kubectl get pods -n istio-system -l istio=eastwestgateway --context k3d-cluster-a
kubectl logs -n istio-system -l istio=eastwestgateway --context k3d-cluster-a
```

### Check ServiceEntry
```bash
kubectl get serviceentry -n demo-dr --context k3d-cluster-b
kubectl describe serviceentry cluster-a-hello-services -n demo-dr --context k3d-cluster-b
```

### Test Gateway Directly
```bash
# From cluster-b pod with sidecar
kubectl exec -n demo-dr test-pod --context k3d-cluster-b -- \
  curl -v http://hello-0.hello.demo.svc.cluster.local:8080
```

### Check Sidecar Config
```bash
kubectl exec -n demo-dr test-pod -c istio-proxy --context k3d-cluster-b -- \
  curl -s localhost:15000/clusters | grep hello
```

### Verify Certificates
```bash
# Both should have same root-cert.pem
kubectl get secret cacerts -n istio-system --context k3d-cluster-a -o jsonpath='{.data.root-cert\.pem}' | base64 -d
kubectl get secret cacerts -n istio-system --context k3d-cluster-b -o jsonpath='{.data.root-cert\.pem}' | base64 -d
```

## Files

- `setup-clusters.sh` - Create isolated k3d clusters
- `setup-certs.sh` - Generate shared CA certificates
- `deploy-production.sh` - Deploy Istio + gateway + services
- `test-production.sh` - Verify cross-cluster connectivity
- `eastwest-gateway.yaml` - Gateway deployment config
- `hello-service.yaml` - Demo StatefulSet + service
- `cleanup.sh` - Remove everything

## Comparison to Alternatives

### vs Exposed LoadBalancers
- **Security**: Services stay internal vs externally exposed
- **Cost**: One LoadBalancer vs one per service
- **Encryption**: Automatic mTLS vs manual TLS setup

### vs Shared Network
- **Realistic**: Simulates actual datacenter isolation
- **Security**: Gateway is controlled entry point
- **Production-ready**: Works with real VPNs/VPCs

### vs Full Auto-Discovery
- **Simpler**: No remote secrets or API cross-access
- **Explicit**: You control what's exposed
- **Database-appropriate**: DBs don't need auto-discovery

## Key Takeaways

1. **Different namespaces eliminate aliases** - Use actual service names
2. **Gateway = single point of connectivity** - One external IP for all services
3. **ServiceEntry = DNS mapping** - Apps use DNS, not IPs
4. **mTLS via shared CA** - Encrypted by default
5. **Services stay internal** - Security best practice

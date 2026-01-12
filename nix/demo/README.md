# Istio Multi-Primary Multi-Network (Official Approach)

Production-ready Istio setup following the official [Istio multi-primary multi-network documentation](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/) for cross-datacenter database replication.

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

./setup-clusters.sh      # Create k3d clusters with proper TLS SANs
./deploy.sh              # Deploy Istio with endpoint discovery
./test.sh                # Verify connectivity
./cleanup.sh             # Remove all
```

**k3d-Specific Configuration:**
- `setup-clusters.sh` creates a dedicated Docker network `k3d-multicluster` (172.24.0.0/16)
- Clusters are created with `--network k3d-multicluster` for predictable IP assignment
- API server certificates include TLS SANs for network IPs (.2-.15 range)
- This enables secure cross-cluster API access without `insecure-skip-tls-verify`

**What Makes This Official Istio Approach:**
- **Endpoint Discovery**: Clusters share Kubernetes API access via remote secrets
- **Envoy DNS Proxy**: Intercepts DNS queries before CoreDNS
- **Auto-allocated VIPs**: Envoy returns virtual IPs for remote services
- **Standard DNS Names**: Use `hello.demo.svc.cluster.local` without modification
- **No Manual ServiceEntry**: Everything is automatic

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

## How It Works (Official Istio Approach)

### 1. Remote Secrets Enable Endpoint Discovery

```bash
istioctl create-remote-secret --context=cluster-a --name=cluster-a | \
  kubectl apply -f - --context=cluster-b
```

**What this does:**
- Creates Kubernetes Secret in cluster-b with cluster-a API credentials
- Istiod in cluster-b watches cluster-a's Kubernetes API
- Automatic service discovery: cluster-b knows about ALL services in cluster-a
- Istiod configures Envoy sidecars with routing information

### 2. Envoy DNS Proxy (The Magic)

**Traditional approach (doesn't work):**
```
App → CoreDNS → NXDOMAIN (service doesn't exist locally) → FAIL
```

**Istio's approach (works):**
```
App → Envoy DNS Proxy (127.0.0.1:15053) → Returns VIP → App uses VIP → Envoy routes
```

**How DNS resolution works:**
1. iptables redirects DNS queries (UDP port 53) to Envoy at `127.0.0.1:15053`
2. Envoy checks its service registry (populated by istiod from both clusters)
3. Envoy finds `hello.demo.svc.cluster.local` (discovered from cluster-a)
4. Envoy returns auto-allocated virtual IP (e.g., `240.240.0.1`)
5. CoreDNS never consulted - Envoy answered first

### 3. East-West Gateway for Cross-Network Traffic

Both clusters get east-west gateways:
- Dedicated to cross-cluster traffic
- TLS passthrough with AUTO_PASSTHROUGH mode
- Routes based on SNI (Server Name Indication)
- Services stay internal - only gateway is accessible

### 4. Transparent Routing

When app makes request to the VIP Envoy provided:
1. App: `GET http://240.240.0.1:8080`
2. Envoy intercepts (iptables redirect port 15001)
3. Envoy knows VIP maps to `hello.demo.svc.cluster.local` in cluster-a
4. Envoy routes through east-west gateway
5. Gateway forwards to actual service
6. mTLS encrypted end-to-end

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

## Official Approach vs Manual ServiceEntry

### Previous Manual Approach (What We Used Before)

**Configuration:**
- Manual ServiceEntry with hardcoded VIP
- No endpoint discovery
- CoreDNS handled DNS queries

**Problems:**
```bash
# This failed - DNS couldn't resolve
curl http://hello.demo.svc.cluster.local:8080
→ CoreDNS returns NXDOMAIN

# Had to use hardcoded VIP
curl http://240.240.0.10:8080
→ Works, but not maintainable
```

**Limitations:**
- Can't use standard Kubernetes DNS names
- Manual ServiceEntry for each service
- Hardcoded IPs and ports
- No automatic endpoint updates
- Doesn't scale

### Official Istio Approach (What We Use Now)

**Configuration:**
- Remote secrets for endpoint discovery
- Envoy DNS proxy intercepts queries
- Auto-allocated VIPs

**Success:**
```bash
# Standard Kubernetes DNS name works!
curl http://hello.demo.svc.cluster.local:8080
→ Envoy DNS proxy returns VIP → Routes correctly
```

**Benefits:**
- ✅ Standard Kubernetes DNS names work
- ✅ No manual ServiceEntry needed
- ✅ Automatic service discovery
- ✅ Dynamic endpoint updates
- ✅ Production-ready and scalable
- ✅ Follows official Istio best practices

### Comparison to Other Alternatives

**vs Exposed LoadBalancers per Service:**
- **Security**: Services stay internal vs externally exposed
- **Cost**: One gateway vs LoadBalancer per service
- **Encryption**: Automatic mTLS vs manual TLS setup

**vs Shared Flat Network:**
- **Realistic**: Simulates actual datacenter isolation
- **Security**: Gateway is controlled entry point
- **Production-ready**: Works with real VPNs/VPCs

## Key Takeaways

1. **Different namespaces eliminate aliases** - Use actual service names
2. **Gateway = single point of connectivity** - One external IP for all services
3. **ServiceEntry = DNS mapping** - Apps use DNS, not IPs
4. **mTLS via shared CA** - Encrypted by default
5. **Services stay internal** - Security best practice

# Multi-Cluster Istio Setup

Multi-primary multi-network Istio configuration for cross-datacenter database replication using k3d clusters.

## Quick Start

```bash
cd nix/wookie-nixpkgs

# Stand up multi-cluster stack (creates clusters + deploys everything)
nix run .#up-multi

# Test cross-cluster connectivity
nix run .#test

# Tear down
nix run .#down-multi
```

## Architecture

```
Datacenter 1 (Cluster A)           Datacenter 2 (Cluster B)
┌──────────────────────┐          ┌──────────────────────┐
│ Namespace: demo      │          │ Namespace: demo-dr   │
│                      │          │                      │
│ Services:            │          │ Test pods:           │
│ - helloworld (3x)    │          │ - Can reach demo     │
│   (NOT exposed)      │          │   via DNS name       │
│                      │          │                      │
│ East-West Gateway    │◄─────────│ East-West Gateway    │
│ (External IP)        │  mTLS    │ (External IP)        │
└──────────────────────┘          └──────────────────────┘
        Network: network1                Network: network2
        172.24.0.x                        172.24.0.y
```

## What Gets Deployed

### Cluster A (Primary)
- Namespace: `demo`
- Istio control plane (istiod)
- East-west gateway (port 15443)
- Helloworld demo app (3 replicas)
- Network: `network1`
- Cluster name: `cluster-a`

### Cluster B (DR)
- Namespace: `demo-dr`
- Istio control plane (istiod)
- East-west gateway (port 15443)
- Network: `network2`
- Cluster name: `cluster-b`

## How It Works

### 1. Shared Docker Network
Both k3d clusters are created on a shared Docker network `k3d-multicluster` (172.24.0.0/16), which simulates cross-datacenter connectivity.

### 2. Remote Secrets Enable Endpoint Discovery
```bash
istioctl create-remote-secret --context=cluster-a --name=cluster-a | \
  kubectl apply -f - --context=cluster-b
```
- Istiod in cluster-b watches cluster-a's Kubernetes API
- Automatic service discovery across clusters
- No manual ServiceEntry needed

### 3. Envoy DNS Proxy
- Envoy intercepts DNS queries before CoreDNS
- Returns auto-allocated virtual IPs for remote services
- Standard Kubernetes DNS names work: `helloworld.demo.svc.cluster.local`

### 4. East-West Gateway
- Dedicated gateway for cross-cluster traffic
- TLS passthrough with SNI routing
- Services remain internal - only gateway is exposed

### 5. MeshNetworks Configuration
Istiod is configured with meshNetworks to route cross-network traffic through gateways:
```yaml
networks:
  network1:
    endpoints:
    - fromRegistry: cluster-a
    gateways:
    - address: 172.24.0.x
      port: 15443
  network2:
    endpoints:
    - fromRegistry: cluster-b
    gateways:
    - address: 172.24.0.y
      port: 15443
```

## Commands

```bash
nix run .#up-multi    # Stand up (create clusters + deploy both)
nix run .#down-multi  # Tear down (delete clusters)
nix run .#test        # Test cross-cluster connectivity
```

Build outputs:
```bash
nix build .#manifests-cluster-a
nix build .#manifests-cluster-b
nix build .#helmfile-cluster-a
nix build .#helmfile-cluster-b
```

Granular operations available as packages: `create-clusters`, `delete-clusters`, `status-clusters`, `deploy-cluster-a`, `deploy-cluster-b`, `diff-cluster-a`, `diff-cluster-b`, `destroy-cluster-a`, `destroy-cluster-b`, `deploy-multi-cluster-istio`

## Configuration

Edit `flake.nix` to customize:

```nix
clusterAConfig = system: mkConfig system [
  ./modules/projects/wookie
  ./modules/targets/multi-cluster-k3d.nix
  {
    targets.multi-cluster-k3d.enable = true;

    projects.wookie = {
      enable = true;
      clusterRole = "primary";
      namespace = "demo";

      istio = {
        enable = true;
        version = "1_28_2";
        eastWestGateway.enabled = true;
      };

      demo-helloworld = {
        enable = true;
        replicas = 3;
      };
    };
  }
];
```

## Testing Cross-Cluster Connectivity

The test script creates a test pod in cluster-b and verifies:

1. DNS resolution of `helloworld.demo.svc.cluster.local`
2. HTTP requests reach services in cluster-a
3. Load balancing across replicas
4. Sidecar injection and mTLS
5. Remote secret configuration
6. Envoy endpoint discovery

Expected output:
```
✓ SUCCESS: DNS resolution and routing working!
  Response: Hello version: v1, instance: helloworld-v1-xxx
```

## Troubleshooting

### Check Gateway IPs
```bash
kubectl get svc istio-eastwestgateway -n istio-system --context=k3d-cluster-a
kubectl get svc istio-eastwestgateway -n istio-system --context=k3d-cluster-b
```

### Verify Remote Secrets
```bash
kubectl get secrets -n istio-system --context=k3d-cluster-a | grep istio-remote-secret
kubectl get secrets -n istio-system --context=k3d-cluster-b | grep istio-remote-secret
```

### Check MeshNetworks Config
```bash
kubectl get configmap istio -n istio-system --context=k3d-cluster-b -o yaml | grep -A 20 meshNetworks
```

### Verify Endpoint Discovery
```bash
kubectl exec -n istio-system deployment/istiod --context=k3d-cluster-b -- \
  curl -s localhost:15014/debug/endpointz | grep helloworld
```

### Check Envoy Config in Test Pod
```bash
kubectl exec test-pod -n demo-dr -c istio-proxy --context=k3d-cluster-b -- \
  pilot-agent request GET clusters | grep hello
```

## For PXC Async Replication

This same pattern can be used for cross-cluster database replication:

### Cluster A (Primary - namespace: wookie)
```nix
projects.wookie = {
  namespace = "wookie";
  # Deploy PXC StatefulSet here
};
```

### Cluster B (Replica - namespace: wookie-dr)
```nix
projects.wookie = {
  namespace = "wookie-dr";
  # Configure async replication here
};
```

Benefits:
- No `pxc.expose=true` needed
- No external LoadBalancer per pod
- Use DNS names (no IP addresses)
- mTLS encryption via gateway
- Single gateway for all services
- Services remain internal

## Network Configuration

### k3d Setup
- Network: `k3d-multicluster` (172.24.0.0/16)
- Cluster A: 172.24.0.2-172.24.0.7 (estimated range)
- Cluster B: 172.24.0.8-172.24.0.15 (estimated range)
- API servers include TLS SANs for these IPs

### Production Setup
- VPN, VPC peering, or dedicated connection
- East-west gateway must have routable IP between datacenters
- Options: AWS VPC peering, GCP VPC peering, Azure VNet peering, IPsec VPN

## Directory Structure

```
nix/wookie-nixpkgs/
├── flake.nix                          # Main flake with multi-cluster configs
├── modules/
│   ├── platform/
│   │   ├── kubernetes/                # Kubernetes deployment system
│   │   └── backends/
│   │       └── helmfile.nix          # Helmfile backend
│   ├── projects/wookie/
│   │   ├── default.nix               # Wookie project definition
│   │   ├── istio.nix                 # Istio component
│   │   └── demo-helloworld.nix       # Demo app component
│   └── targets/
│       ├── local-k3d.nix             # Single-cluster target
│       └── multi-cluster-k3d.nix     # Multi-cluster target
├── lib/
│   ├── kubelib.nix                   # Kubernetes helper functions
│   └── helpers/
│       └── test-multi-cluster.sh     # Test script
└── pkgs/charts/
    └── charts.nix                    # Helm chart definitions
```

## Differences from nix/demo

This implementation uses the Nix module system with:
- Declarative configuration via Nix modules
- Separate targets for cluster-a and cluster-b
- Modular project structure (wookie with istio + demo-helloworld components)
- Batch-based deployment system (namespaces → CRDs → operators → services)
- Helmfile backend for orchestrated deployment with dependency management
- Automatic manifest generation from Helm charts
- Type-safe configuration with module options

The old `nix/demo` used shell scripts and the old flake structure.

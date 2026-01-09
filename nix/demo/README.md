# Cross-Cluster Service Discovery Demo

Demonstrates Istio ServiceEntry for cross-cluster communication between two data centers, simulating the setup for PXC async replication.

## Architecture

- **Cluster A**: Primary site with hello service (3 pods)
- **Cluster B**: Remote site accessing cluster-a via Istio ServiceEntry
- **Network**: Shared Docker network simulates VPN/VPC peering
- **Istio**: Service mesh provides routing and observability

## Network Setup

Two k3d clusters on separate Docker networks connected via shared network (`k3d-interconnect`), simulating:
- VPC peering (AWS/GCP)
- VPN/IPsec tunnel
- Private WAN connection

This enables direct pod-to-pod IP routing across clusters.

## Usage

```bash
cd demo
./deploy.sh   # Creates clusters, connects networks, deploys everything
./test.sh     # Verifies cross-cluster connectivity
./cleanup.sh  # Removes everything
```

## How It Works

1. **Network Layer**: Docker network connects cluster nodes (simulates data center interconnect)
2. **ServiceEntry**: Defines remote endpoints in cluster-b pointing to cluster-a pod IPs
3. **Static Resolution**: Uses actual pod IPs (requires network connectivity)
4. **Istio Routing**: Sidecar proxies route traffic to remote pods

## For PXC Async Replication

Replace hello pods with PXC StatefulSet:

```nix
pxc-remote = serviceEntryLib.mkServiceEntry {
  name = "pxc-prod";
  namespace = "pxc";
  hosts = [
    "pxc-cluster-pxc-0.pxc-cluster-pxc.pxc.svc.cluster.local"
    "pxc-cluster-pxc-1.pxc-cluster-pxc.pxc.svc.cluster.local"
    "pxc-cluster-pxc-2.pxc-cluster-pxc.pxc.svc.cluster.local"
  ];
  ports = [{ number = 3306; name = "mysql"; protocol = "TCP"; }];
  location = "MESH_EXTERNAL";
  resolution = "STATIC";
  endpoints = [
    { address = "10.42.2.5"; }  # pxc-0 IP
    { address = "10.42.0.6"; }  # pxc-1 IP
    { address = "10.42.1.7"; }  # pxc-2 IP
  ];
};
```

Benefits:
- No `pxc.expose = true` needed
- No external LoadBalancer IPs
- Direct pod-to-pod communication
- Service names instead of IPs in config

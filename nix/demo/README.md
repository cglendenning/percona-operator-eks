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

1. **Network Layer**: Shared Docker network connects cluster nodes (simulates VPN/VPC peering)
2. **NodePort Services**: Expose pods in cluster-a via stable node IPs
3. **ServiceEntry**: Maps DNS names in cluster-b to node IPs + NodePorts in cluster-a
4. **Istio Routing**: Sidecar proxies route traffic across clusters transparently

The flow: `curl hello-0...:8080` → Istio ServiceEntry → `172.21.0.2:30080` → Pod in cluster-a

## For PXC Async Replication

Same pattern with NodePort services for each PXC pod:

```yaml
# NodePort services for PXC pods (in source cluster)
apiVersion: v1
kind: Service
metadata:
  name: pxc-0-external
  namespace: pxc
spec:
  type: NodePort
  selector:
    statefulset.kubernetes.io/pod-name: pxc-cluster-pxc-0
  ports:
  - port: 3306
    nodePort: 30306
```

```nix
# ServiceEntry in replica cluster
pxc-remote = pkgs.runCommand "pxc-serviceentry" { } ''
  cat > $out/manifest.yaml << 'EOF'
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: pxc-0-external
  namespace: pxc
spec:
  hosts:
  - "pxc-cluster-pxc-0.pxc-cluster-pxc.pxc.svc.cluster.local"
  addresses:
  - "10.100.1.5"  # Source cluster node IP
  ports:
  - number: 3306
    name: mysql
    protocol: TCP
    targetPort: 30306
  location: MESH_EXTERNAL
  resolution: STATIC
  endpoints:
  - address: "10.100.1.5"
    ports:
      mysql: 30306
EOF
'';
```

Benefits:
- No `pxc.expose = true` needed
- No external LoadBalancer
- Use DNS names instead of IPs
- Network policy friendly

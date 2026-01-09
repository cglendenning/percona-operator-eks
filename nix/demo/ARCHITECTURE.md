# Multi-Cluster Istio Architecture (Without mTLS)

## Overview
Two isolated Kubernetes clusters connected via shared Docker network, simulating VPN/VPC peering between data centers.

## Network Topology

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Docker Host (macOS)                                │
│                                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                     k3d-shared Network (172.22.0.0/16)                     │ │
│  │                    (Simulates VPN/VPC Peering)                             │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│         │                                                   │                   │
│         │                                                   │                   │
│  ┌──────▼──────────────────────────────┐   ┌──────────────▼───────────────────┐ │
│  │   Cluster A (k3d-cluster-a)         │   │   Cluster B (k3d-cluster-b)      │ │
│  │   Network: 172.19.0.0/16            │   │   Network: 172.20.0.0/16         │ │
│  │   k3d-shared IP: 172.22.0.6         │   │   k3d-shared IP: 172.22.0.x      │ │
│  │                                     │   │                                  │ │
│  │  ┌─────────────────────────────┐    │   │  ┌─────────────────────────┐     │ │
│  │  │  istio-system namespace     │    │   │  │  istio-system namespace │     │ │
│  │  │  ┌──────────────────────┐   │    │   │  │  ┌──────────────────┐   │     │ │
│  │  │  │ Istiod (Control Plane)│  │    │   │  │  │ Istiod           │   │     │ │
│  │  │  └──────────────────────┘   │    │   │  │  └──────────────────┘   │     │ │
│  │  │                             │    │   │  │                         │     │ │
│  │  │  ┌──────────────────────┐   │    │   │  └─────────────────────────┘     │ │
│  │  │  │ East-West Gateway    │   │    │   │                                  │ │
│  │  │  │ Pod IP: 10.42.2.6    │   │    │   │  ┌─────────────────────────┐     │ │
│  │  │  │ Listens: 0.0.0.0:15443│  │    │   │  │  demo-dr namespace      │     │ │
│  │  │  │ Protocol: HTTP (plain)│  │    │   │  │  ┌──────────────────┐   │     │ │
│  │  │  └──────────▲───────────┘   │    │   │  │  │ test-remote pod  │   │     │ │
│  │  │             │               │    │   │  │  │ IP: 10.42.x.x    │   │     │ │
│  │  │  ┌──────────┴───────────┐   │    │   │  │  │                  │   │     │ │
│  │  │  │ Gateway Service      │   │    │   │  │  │ ┌──────────────┐ │   │     │ │
│  │  │  │ Type: NodePort       │   │    │   │  │  │ │ curl client  │ │   │     │ │
│  │  │  │ NodePort: 30443      │   │    │   │  │  │ └──────┬───────┘ │   │     │ │
│  │  │  │ TargetPort: 15443    │   │    │   │  │  │        │         │   │     │ │
│  │  │  └──────────────────────┘   │    │   │  │  │ ┌──────▼───────┐ │   │     │ │
│  │  └─────────────────────────────┘    │   │  │  │ │ Istio Sidecar│ │   │     │ │
│  │                                     │   │  │  │ │ (Envoy)      │ │   │     │ │
│  │  ┌─────────────────────────────┐    │   │  │  │ └──────┬───────┘ │   │     │ │
│  │  │  demo namespace             │    │   │  │  └────────┼─────────┘   │     │ │
│  │  │  ┌──────────────────────┐   │    │   │  │           │             │     │ │
│  │  │  │ hello StatefulSet    │   │    │   │  │  ┌────────▼──────────┐  │     │ │
│  │  │  │                      │   │    │   │  │  │ ServiceEntry      │  │     │ │
│  │  │  │ hello-0 (10.42.0.3)  │   │    │   │  │  │                   │  │     │ │
│  │  │  │ hello-1 (10.42.2.3)  │   │    │   │  │  │ Host:             │  │     │ │
│  │  │  │ hello-2 (10.42.1.5)  │   │    │   │  │  │   hello.demo...   │  │     │ │
│  │  │  │                      │   │    │   │  │  │ Address:          │  │     │ │
│  │  │  │ Each with Istio      │   │    │   │  │  │   240.240.0.10    │  │     │ │
│  │  │  │ sidecar              │   │    │   │  │  │ Endpoint:         │  │     │ │
│  │  │  └──────────────────────┘   │    │   │  │  │   172.22.0.6:30443│  │     │ │
│  │  │            ▲                │    │   │  │  └───────────────────┘  │     │ │
│  │  │  ┌─────────┴──────────┐     │    │   │  └─────────────────────────┘     │ │
│  │  │  │ hello Service      │     │    │   │                                  │ │
│  │  │  │ Type: ClusterIP    │     │    │   │                                  │ │
│  │  │  │ (headless)         │     │    │   │                                  │ │
│  │  │  └────────────────────┘     │    │   │                                  │ │
│  │  │                             │    │   │                                  │ │
│  │  │  ┌─────────────────────┐    │    │   │                                  │ │
│  │  │  │ Gateway (Istio CRD) │    │    │   │                                  │ │
│  │  │  │ Port: 15443         │    │    │   │                                  │ │
│  │  │  │ Protocol: HTTP      │    │    │   │                                  │ │
│  │  │  │ Hosts: *            │    │    │   │                                  │ │
│  │  │  └─────────────────────┘    │    │   │                                  │ │
│  │  │                             │    │   │                                  │ │
│  │  │  ┌─────────────────────┐    │    │   │                                  │ │
│  │  │  │ VirtualService      │    │    │   │                                  │ │
│  │  │  │ Routes: * ->        │    │    │   │                                  │ │
│  │  │  │   hello.demo:8080   │    │    │   │                                  │ │
│  │  │  └─────────────────────┘    │    │   │                                  │ │
│  │  └─────────────────────────────┘    │   │                                  │ │
│  └─────────────────────────────────────┘   └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Request Flow: Cluster B → Cluster A

```
Cluster B (demo-dr namespace)              k3d-shared network              Cluster A (demo namespace)

┌─────────────────────┐                                                    
│  curl client        │                                                    
│  in test-remote pod │                                                    
└──────────┬──────────┘                                                    
           │                                                               
           │ 1. curl http://240.240.0.10:8080                            
           │    (synthetic IP from ServiceEntry)                          
           │                                                               
           ▼                                                               
┌─────────────────────┐                                                    
│  Istio Sidecar      │                                                    
│  (Envoy proxy)      │                                                    
│  - Looks up         │                                                    
│    ServiceEntry     │                                                    
│  - Maps synthetic   │                                                    
│    IP to endpoint   │                                                    
│  - Uses plain HTTP  │                                                    
│    (no TLS)         │                                                    
└──────────┬──────────┘                                                    
           │                                                               
           │ 2. HTTP GET to 172.22.0.6:30443                             
           │    (node IP on shared network)                               
           │                                                               
           └──────────────────────────────┐                               
                                          │                                
                   VPN/VPC Peering        │                                
                   (simulated by          │                                
                   shared Docker net)     │                                
                                          │                                
                                          ▼                                
                                   ┌─────────────────────┐                
                                   │  Node IP:30443      │                
                                   │  (172.22.0.6)       │                
                                   │  on k3d-shared net  │                
                                   └──────────┬──────────┘                
                                              │                            
                                              │ 3. kube-proxy forwards    
                                              │    (NodePort → Pod)       
                                              │                            
                                              ▼                            
                                   ┌─────────────────────┐                
                                   │ East-West Gateway   │                
                                   │ Pod: 10.42.2.6:15443│                
                                   │                     │                
                                   │ Gateway matches:    │                
                                   │  Port: 15443        │                
                                   │  Protocol: HTTP     │                
                                   │  Hosts: * (any)     │                
                                   └──────────┬──────────┘                
                                              │                            
                                              │ 4. VirtualService routes  
                                              │    to hello.demo:8080     
                                              │                            
                                              ▼                            
                                   ┌─────────────────────┐                
                                   │ hello Service       │                
                                   │ (ClusterIP)         │                
                                   │ Load balances:      │                
                                   └──────────┬──────────┘                
                                              │                            
                                              │ 5. Routes to one of:      
                         ┌────────────────────┼────────────────────┐      
                         │                    │                    │      
                         ▼                    ▼                    ▼      
                   ┌──────────┐         ┌──────────┐         ┌──────────┐
                   │ hello-0  │         │ hello-1  │         │ hello-2  │
                   │ 10.42.0.3│         │ 10.42.2.3│         │ 10.42.1.5│
                   │          │         │          │         │          │
                   │ + sidecar│         │ + sidecar│         │ + sidecar│
                   └────┬─────┘         └────┬─────┘         └────┬─────┘
                        │                    │                    │      
                        │ 6. Response: "Hello from hello-X in Cluster A!"
                        │                    │                    │      
                        └────────────────────┴────────────────────┘      
                                              │                            
                                              │ Same path in reverse       
                                              ▼                            
                                         Back to curl                      
```

## Key Components

### Cluster A (Source)
- **Namespace**: `demo`
- **Services**: 
  - `hello` (headless ClusterIP for StatefulSet)
  - `istio-eastwestgateway` (NodePort 30443)
- **Pods**: 
  - `hello-0`, `hello-1`, `hello-2` (with Istio sidecars)
  - `istio-eastwestgateway` pod (gateway proxy)
- **Istio Config**:
  - **Gateway**: Port 15443, HTTP protocol, hosts: *
  - **VirtualService**: Routes all traffic to hello.demo.svc.cluster.local:8080

### Cluster B (Target)
- **Namespace**: `demo-dr`
- **Istio Config**:
  - **ServiceEntry**:
    - Host: `hello.demo.svc.cluster.local`
    - Synthetic IP: `240.240.0.10` (optional)
    - Endpoint: `172.22.0.6:30443` (node IP on shared network)
    - Resolution: STATIC
    - Location: MESH_INTERNAL

### Network Configuration
- **k3d-cluster-a network**: 172.19.0.0/16 (isolated)
- **k3d-cluster-b network**: 172.20.0.0/16 (isolated)
- **k3d-shared network**: 172.22.0.0/16 (connects both clusters, simulates VPN/VPC peering)

## Why This Architecture Works

### NodePort is Required
The gateway pod has IP `10.42.x.x` on Kubernetes CNI overlay network, which is not routable from cluster-b. By using NodePort:
1. Traffic hits the node's IP on the shared network (`172.22.0.6:30443`)
2. kube-proxy forwards to the gateway pod (`10.42.2.6:15443`)
3. Gateway routes to backend service

Without NodePort, traffic would try to reach the pod IP directly and fail.

### Plain HTTP (No mTLS)
- **Gateway**: Configured for plain HTTP on port 15443
- **Sidecar**: Configured to send plain HTTP (no DestinationRule forcing TLS)
- **ServiceEntry**: MESH_INTERNAL with STATIC resolution
- This simplifies the demo while maintaining the correct routing architecture

### Synthetic IP is Optional
The ServiceEntry creates a DNS name (`hello.demo.svc.cluster.local`) that can be used directly. The synthetic IP (`240.240.0.10`) is optional and just provides an alternative way to reference the service.

**You can access the service either way:**
- `curl http://hello.demo.svc.cluster.local:8080` (DNS name)
- `curl http://240.240.0.10:8080` (synthetic IP)

## Traffic Path Summary

```
Client → Sidecar → Node IP:30443 → kube-proxy → Gateway Pod:15443 → Backend Service
```

## Production Considerations

### For PXC Cross-Cluster Replication

Since your namespaces are different (`demo` vs `demo-dr`), there's no name collision. You can directly reference cluster A's services without aliases:

**In Cluster B (demo-dr namespace):**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: cluster-a-pxc-0
  namespace: demo-dr
spec:
  hosts:
  - "db-pxc-0.db-pxc.demo.svc.cluster.local"  # Cluster A's actual service name
  endpoints:
  - address: "172.22.0.6"  # Gateway node IP on shared network
    ports:
      mysql: 30443           # NodePort for gateway
```

Then in cluster B, PXC can connect using:
```
SOURCE_HOST='db-pxc-0.db-pxc.demo.svc.cluster.local'
```

### Enable mTLS for Production
For production, add a DestinationRule:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: cluster-a-services-mtls
  namespace: demo-dr
spec:
  host: "*.demo.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
      sni: db-pxc-0.demo.svc.cluster.local
```

And update Gateway to use TLS mode instead of plain HTTP.

## Files
- `setup-clusters.sh` - Creates two k3d clusters
- `deploy.sh` - Deploys Istio, services, gateway, and ServiceEntry
- `test.sh` - Tests cross-cluster connectivity
- `cleanup.sh` - Destroys clusters and networks
- `README.md` - Usage instructions

#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Production Multi-Cluster Istio ==="
echo "Two datacenters connected ONLY via east-west gateway"
echo ""

# Step 1: Setup shared CA certificates for mTLS
echo "Step 1: Generating shared root CA..."
./setup-certs.sh

# Step 2: Build Istio manifests
echo ""
echo "Step 2: Building Istio manifests..."
cd ..
nix build .#istio-all
cd demo

# Step 3: Deploy Istio to Cluster A
echo ""
echo "Step 3: Deploying Istio to Cluster A..."
kubectl config use-context k3d-cluster-a
kubectl apply -f ../result/manifest.yaml --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster A"

# Step 4: Deploy east-west gateway with LoadBalancer in Cluster A
echo ""
echo "Step 4: Deploying east-west gateway to Cluster A..."
kubectl apply -f eastwest-gateway.yaml --context k3d-cluster-a
kubectl wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system --context k3d-cluster-a

# Get the gateway endpoint  
echo "Waiting for LoadBalancer endpoint..."
sleep 10
GATEWAY_HOST=$(kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
GATEWAY_PORT="15443"

if [ -z "$GATEWAY_HOST" ]; then
  # k3d exposes LoadBalancer on host via NodePort
  GATEWAY_HOST="host.k3d.internal"
  GATEWAY_PORT=$(kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a -o jsonpath='{.spec.ports[?(@.name=="tls")].nodePort}')
fi

echo "East-west gateway: $GATEWAY_HOST:$GATEWAY_PORT"

# Step 5: Deploy Istio to Cluster B
echo ""
echo "Step 5: Deploying Istio to Cluster B..."
kubectl config use-context k3d-cluster-b
kubectl apply -f ../result/manifest.yaml --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster B"

# Step 6: Deploy hello service to Cluster A
echo ""
echo "Step 6: Deploying hello service to Cluster A..."
kubectl config use-context k3d-cluster-a
kubectl delete svc hello -n demo 2>/dev/null || true
kubectl apply -f hello-service.yaml

echo "Waiting for hello pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=60s

echo ""
echo "Hello pods in Cluster A:"
kubectl get pods -n demo -o wide --context k3d-cluster-a

# Step 7: Expose services via east-west gateway
echo ""
echo "Step 7: Exposing services via east-west gateway..."
kubectl apply --context k3d-cluster-a -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
spec:
  selector:
    istio: eastwestgateway
  servers:
  - port:
      number: 15443
      name: tls
      protocol: TLS
    tls:
      mode: AUTO_PASSTHROUGH
    hosts:
    - "*.local"
EOF

# Step 8: Create ServiceEntry in cluster-b with DNS aliases
echo ""
echo "Step 8: Creating DNS aliases in cluster-b..."

kubectl create namespace demo --context k3d-cluster-b 2>/dev/null || echo "Namespace demo already exists"
kubectl label namespace demo istio-injection=enabled --context k3d-cluster-b --overwrite

# Create ServiceEntry with aliases pointing to gateway
kubectl apply --context k3d-cluster-b -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-hello-0
  namespace: demo
spec:
  hosts:
  - "src-hello-0.demo.svc.cluster.local"
  addresses:
  - "240.240.0.10"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$GATEWAY_HOST"
    ports:
      http: $GATEWAY_PORT
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-hello-1
  namespace: demo
spec:
  hosts:
  - "src-hello-1.demo.svc.cluster.local"
  addresses:
  - "240.240.0.11"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$GATEWAY_HOST"
    ports:
      http: $GATEWAY_PORT
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-hello-2
  namespace: demo
spec:
  hosts:
  - "src-hello-2.demo.svc.cluster.local"
  addresses:
  - "240.240.0.12"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$GATEWAY_HOST"
    ports:
      http: $GATEWAY_PORT
EOF

echo ""
echo "Deployment complete!"
echo ""
echo "Architecture:"
echo "  Cluster A: Pods on private network (NOT accessible from cluster-b)"
echo "  Gateway: $GATEWAY_HOST:$GATEWAY_PORT (ONLY connection point)"
echo "  Cluster B: DNS aliases (src-hello-X) → route via gateway"
echo ""
echo "This correctly simulates two isolated datacenters."
echo ""
echo "Test with: ./test-simple-multicluster.sh"

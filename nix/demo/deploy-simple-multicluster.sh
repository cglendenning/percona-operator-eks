#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Simple Multi-Cluster Istio with DNS-based ServiceEntry ==="

# Step 1: Setup shared CA certificates for mTLS
echo ""
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

# Step 4: Deploy east-west gateway to Cluster A
echo ""
echo "Step 4: Deploying east-west gateway to Cluster A..."
kubectl apply -f eastwest-gateway.yaml --context k3d-cluster-a
kubectl wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system --context k3d-cluster-a

# Get east-west gateway service IP
EW_SERVICE=$(kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -z "$EW_SERVICE" ]; then
  # k3d LoadBalancer gets node IP
  EW_SERVICE=$(kubectl get nodes --context k3d-cluster-a -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
fi
echo "Cluster A east-west gateway at: $EW_SERVICE:15443"

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
echo "Step 7: Exposing services through east-west gateway..."
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
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: hello-gateway
  namespace: demo
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
    - "*.demo.svc.cluster.local"
EOF

echo "Services exposed via east-west gateway"

# Step 8: Connect clusters via shared network
echo ""
echo "Step 8: Connecting clusters via shared Docker network..."
./connect-clusters.sh

# Get the actual gateway IP on shared network
EW_SHARED_IP=$(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-interconnect -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
echo "East-west gateway accessible at: $EW_SHARED_IP:15443"

# Step 9: Create DNS-based ServiceEntry in cluster-b
echo ""
echo "Step 9: Creating explicit DNS-based ServiceEntry in cluster-b..."

# Create ServiceEntry that maps aliases to actual service DNS names
kubectl apply --context k3d-cluster-b -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-hello-0
  namespace: demo
spec:
  hosts:
  - "src-hello-0.demo.svc.cluster.local"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$EW_SHARED_IP"
    ports:
      http: 15443
    labels:
      service: hello-0
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-hello-1
  namespace: demo
spec:
  hosts:
  - "src-hello-1.demo.svc.cluster.local"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$EW_SHARED_IP"
    ports:
      http: 15443
    labels:
      service: hello-1
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: src-hello-2
  namespace: demo
spec:
  hosts:
  - "src-hello-2.demo.svc.cluster.local"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$EW_SHARED_IP"
    ports:
      http: 15443
    labels:
      service: hello-2
EOF

echo ""
echo "Deployment complete!"
echo ""
echo "Architecture:"
echo "  Cluster B → src-hello-X alias → ServiceEntry → East-West Gateway ($EW_SHARED_IP:15443) → Cluster A hello-X"
echo ""
echo "Features:"
echo "  - Shared CA for mTLS trust"
echo "  - DNS-based aliases (no pod IPs)"
echo "  - Explicit ServiceEntry (no automatic discovery)"
echo "  - Secure traffic through east-west gateway"
echo ""
echo "Test with: ./test-simple-multicluster.sh"

#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Production Multi-Cluster Istio ==="
echo "Cluster A (demo) → Gateway → Cluster B (demo-dr)"
echo ""

# Step 1: Setup shared CA
echo "Step 1: Generating shared root CA for mTLS..."
./setup-certs.sh

# Step 2: Build Istio
echo ""
echo "Step 2: Building Istio manifests..."
cd ..
nix build .#istio-all
cd demo

# Step 3: Deploy Istio to Cluster A
echo ""
echo "Step 3: Deploying Istio to Cluster A..."
kubectl apply -f ../result/manifest.yaml --context k3d-cluster-a --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system --context k3d-cluster-a
echo "✓ Istio ready in Cluster A"

# Step 4: Deploy east-west gateway in Cluster A
echo ""
echo "Step 4: Deploying east-west gateway..."
kubectl apply -f eastwest-gateway.yaml --context k3d-cluster-a
kubectl wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system --context k3d-cluster-a

# Get gateway endpoint - for k3d, always use host.k3d.internal with NodePort
GATEWAY_HOST="host.k3d.internal"
GATEWAY_PORT=$(kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a -o jsonpath='{.spec.ports[?(@.name=="tls")].nodePort}')
echo "✓ Gateway: $GATEWAY_HOST:$GATEWAY_PORT"
echo "  (Gateway accessible from both clusters via host network)"

# Step 5: Deploy Istio to Cluster B
echo ""
echo "Step 5: Deploying Istio to Cluster B..."
kubectl apply -f ../result/manifest.yaml --context k3d-cluster-b --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system --context k3d-cluster-b
echo "✓ Istio ready in Cluster B"

# Step 6: Deploy hello service in Cluster A (demo namespace)
echo ""
echo "Step 6: Deploying services in Cluster A (demo namespace)..."
kubectl apply -f hello-service.yaml --context k3d-cluster-a

echo "Waiting for pods to be created..."
sleep 10
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=120s --context k3d-cluster-a
echo "✓ Services running in demo namespace"

# Step 7: Expose demo namespace via gateway
echo ""
echo "Step 7: Exposing demo namespace through gateway..."
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
    - "*.demo.svc.cluster.local"
EOF
echo "✓ Gateway configured for cross-cluster access"

# Step 8: Setup demo-dr namespace in Cluster B with ServiceEntry
echo ""
echo "Step 8: Configuring Cluster B (demo-dr namespace) to access Cluster A..."
kubectl create namespace demo-dr --context k3d-cluster-b 2>/dev/null || true
kubectl label namespace demo-dr istio-injection=enabled --context k3d-cluster-b --overwrite

# Create ServiceEntry for cluster-a services using DNS resolution
kubectl apply --context k3d-cluster-b -f - <<EOF
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
  addresses:
  - "240.240.0.10"
  - "240.240.0.11"
  - "240.240.0.12"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: DNS
  endpoints:
  - address: "$GATEWAY_HOST"
    ports:
      http: $GATEWAY_PORT
EOF

echo "✓ ServiceEntry created in demo-dr namespace"

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Architecture:"
echo "  Cluster A (demo):      Services with pods hello-0,1,2"
echo "  Gateway:               $GATEWAY_HOST:$GATEWAY_PORT"
echo "  Cluster B (demo-dr):   Can access via actual DNS names"
echo ""
echo "From Cluster B, reference services by their real names:"
echo "  hello-0.hello.demo.svc.cluster.local:8080"
echo "  hello-1.hello.demo.svc.cluster.local:8080"
echo "  hello-2.hello.demo.svc.cluster.local:8080"
echo ""
echo "For PXC:"
echo "  Cluster A (wookie):    db-pxc-0.db-pxc.wookie.svc.cluster.local"
echo "  Cluster B (wookie-dr): Use SOURCE_HOST='db-pxc-0.db-pxc.wookie.svc.cluster.local'"
echo ""
echo "Test: ./test-production.sh"

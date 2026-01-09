#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Istio Multi-Cluster Demo ==="

# Build Istio manifests
echo "Building Istio manifests..."
cd ..
nix build .#istio-all
cd demo

# Deploy Istio to Cluster A
echo ""
echo "Step 1: Deploying Istio to Cluster A..."
kubectl config use-context k3d-cluster-a
kubectl apply -f ../result/manifest.yaml --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster A"

# Deploy Istio to Cluster B
echo ""
echo "Step 2: Deploying Istio to Cluster B..."
kubectl config use-context k3d-cluster-b
kubectl apply -f ../result/manifest.yaml --validate=false
kubectl wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
echo "Istio deployed to Cluster B"

# Deploy hello service to Cluster A (namespace: demo)
echo ""
echo "Step 3: Deploying hello service to Cluster A..."
kubectl config use-context k3d-cluster-a
cd ..
nix build .#hello-service
kubectl apply -f result/manifest.yaml --context k3d-cluster-a
cd demo

# Wait for sidecar injection and pods ready
echo "Waiting for hello pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=60s --context k3d-cluster-a

echo ""
echo "Hello pods in Cluster A:"
kubectl get pods -n demo -o wide --context k3d-cluster-a

# Deploy east-west gateway to Cluster A
echo ""
echo "Step 4: Deploying east-west gateway to Cluster A..."
kubectl apply --context k3d-cluster-a -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: istio-eastwestgateway
  namespace: istio-system
spec:
  type: LoadBalancer
  selector:
    istio: eastwestgateway
  ports:
  - port: 15443
    name: tls
    protocol: TCP
    targetPort: 15443
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-eastwestgateway
  namespace: istio-system
spec:
  replicas: 1
  selector:
    matchLabels:
      istio: eastwestgateway
  template:
    metadata:
      labels:
        istio: eastwestgateway
        service.istio.io/canonical-name: istio-eastwestgateway
        service.istio.io/canonical-revision: latest
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: istio-proxy
        image: docker.io/istio/proxyv2:1.20.0
        args:
        - proxy
        - router
        - --domain
        - $(POD_NAMESPACE).svc.cluster.local
        - --proxyLogLevel=warning
        - --proxyComponentLogLevel=misc:error
        - --log_output_level=default:info
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: INSTANCE_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: SERVICE_ACCOUNT
          valueFrom:
            fieldRef:
              fieldPath: spec.serviceAccountName
        ports:
        - containerPort: 15443
          protocol: TCP
        - containerPort: 15020
          protocol: TCP
        resources:
          limits:
            cpu: 2000m
            memory: 1024Mi
          requests:
            cpu: 100m
            memory: 128Mi
        volumeMounts:
        - name: istio-envoy
          mountPath: /etc/istio/proxy
        - name: config-volume
          mountPath: /etc/istio/config
        - mountPath: /var/run/secrets/istio
          name: istiod-ca-cert
        - mountPath: /var/run/secrets/tokens
          name: istio-token
          readOnly: true
      volumes:
      - emptyDir: {}
        name: istio-envoy
      - name: config-volume
        configMap:
          name: istio
          optional: true
      - name: istiod-ca-cert
        configMap:
          name: istio-ca-root-cert
      - name: istio-token
        projected:
          sources:
          - serviceAccountToken:
              audience: istio-ca
              expirationSeconds: 43200
              path: istio-token
      serviceAccountName: istio-ingressgateway-service-account
---
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
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: cross-network-hello
  namespace: demo
spec:
  hosts:
  - "*"
  gateways:
  - istio-system/cross-network-gateway
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: hello.demo.svc.cluster.local
        port:
          number: 8080
EOF

echo "Waiting for east-west gateway..."
kubectl wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system --context k3d-cluster-a

# Get gateway IP
GATEWAY_IP=$(kubectl get svc istio-eastwestgateway -n istio-system --context k3d-cluster-a -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "East-west gateway IP: $GATEWAY_IP"

# Create demo-dr namespace in Cluster B
echo ""
echo "Step 5: Creating demo-dr namespace in Cluster B..."
kubectl create namespace demo-dr --context k3d-cluster-b 2>/dev/null || echo "Namespace demo-dr already exists"
kubectl label namespace demo-dr istio-injection=enabled --overwrite --context k3d-cluster-b

# Deploy ServiceEntry to Cluster B
echo ""
echo "Step 6: Deploying ServiceEntry to Cluster B..."
kubectl apply --context k3d-cluster-b -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: cluster-a-services
  namespace: demo-dr
spec:
  hosts:
  - "hello.demo.svc.cluster.local"
  addresses:
  - "240.240.0.10"
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
  resolution: STATIC
  endpoints:
  - address: "$GATEWAY_IP"
    ports:
      http: 15443
EOF

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Cluster A (demo namespace):"
echo "  - 3 hello pods with Istio sidecars"
echo "  - East-west gateway at $GATEWAY_IP:15443"
echo ""
echo "Cluster B (demo-dr namespace):"
echo "  - ServiceEntry routing hello.demo.svc.cluster.local -> gateway"
echo ""
echo "Run './test.sh' to verify cross-cluster connectivity."

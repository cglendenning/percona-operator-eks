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

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: Service
metadata:
  name: hello
  namespace: demo
spec:
  clusterIP: None
  selector:
    app: hello
  ports:
  - port: 8080
    name: http
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: hello
  namespace: demo
spec:
  serviceName: hello
  replicas: 3
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: hashicorp/http-echo:latest
        args:
        - "-text=Hello from $(POD_NAME) in Cluster A!"
        - "-listen=:8080"
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        ports:
        - containerPort: 8080
          name: http
EOF

# Wait for sidecar injection and pods ready
echo "Waiting for hello pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=60s --context k3d-cluster-a

echo ""
echo "Hello pods in Cluster A:"
kubectl get pods -n demo -o wide --context k3d-cluster-a

# Connect clusters via shared Docker network (simulates VPN/VPC peering)
# This allows pods in cluster-b to reach nodes in cluster-a
echo ""
echo "Step 3.5: Connecting clusters via shared Docker network..."
docker network create k3d-shared 2>/dev/null || echo "Network k3d-shared already exists"

# Connect all cluster-a nodes to shared network
for node in $(docker ps --format '{{.Names}}' | grep k3d-cluster-a); do
  docker network connect k3d-shared $node 2>/dev/null || echo "$node already connected"
done

# Connect all cluster-b nodes to shared network
for node in $(docker ps --format '{{.Names}}' | grep k3d-cluster-b); do
  docker network connect k3d-shared $node 2>/dev/null || echo "$node already connected"
done

echo "Clusters connected via k3d-shared network (simulates VPN/VPC peering)"

# Deploy east-west gateway to Cluster A
echo ""
echo "Step 4: Deploying east-west gateway to Cluster A..."
kubectl apply --context k3d-cluster-a -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-eastwestgateway
  namespace: istio-system
---
apiVersion: v1
kind: Service
metadata:
  name: istio-eastwestgateway
  namespace: istio-system
spec:
  type: NodePort
  selector:
    istio: eastwestgateway
  ports:
  - port: 15443
    name: tls
    protocol: TCP
    targetPort: 15443
    nodePort: 30443
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
      serviceAccountName: istio-eastwestgateway
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

# Get the node's IP on the shared network (for NodePort access)
# The gateway service is NodePort, so we point to node-ip:30443
# kube-proxy then forwards to the gateway pod
GATEWAY_POD=$(kubectl get pods -n istio-system -l istio=eastwestgateway --context k3d-cluster-a -o jsonpath='{.items[0].metadata.name}')
GATEWAY_NODE=$(kubectl get pod $GATEWAY_POD -n istio-system --context k3d-cluster-a -o jsonpath='{.spec.nodeName}')
GATEWAY_IP=$(docker inspect $GATEWAY_NODE | jq -r '.[0].NetworkSettings.Networks["k3d-shared"].IPAddress')

echo "Gateway pod: $GATEWAY_POD on node: $GATEWAY_NODE"
echo "Node IP on shared network: $GATEWAY_IP (used for NodePort access)"

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
      http: 30443
EOF

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Cluster A (demo namespace):"
echo "  - 3 hello pods with Istio sidecars"
echo "  - East-west gateway at $GATEWAY_IP:30443 (NodePort on k3d-shared network)"
echo ""
echo "Cluster B (demo-dr namespace):"
echo "  - ServiceEntry routing hello.demo.svc.cluster.local -> gateway"
echo ""
echo "Architecture:"
echo "  Client (cluster-b) -> Sidecar -> Node IP:30443 -> kube-proxy -> Gateway Pod:15443 -> Backend Service"
echo ""
echo "Run './test.sh' to verify cross-cluster connectivity."

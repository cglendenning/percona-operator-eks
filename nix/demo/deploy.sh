#!/usr/bin/env bash
#
# Deploy Istio Multi-Primary Multi-Network (Official Istio Approach)
# Based on: https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/
#
set -euo pipefail

CTX_CLUSTER1="k3d-cluster-a"
CTX_CLUSTER2="k3d-cluster-b"
MESH_ID="mesh1"

echo "=== Deploying Istio Multi-Primary Multi-Network ==="
echo ""
echo "Following official Istio documentation:"
echo "https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/"
echo ""

##############################################################################
# Step 1: Deploy istio-base (CRDs) to both clusters
##############################################################################

echo "Step 1: Building and deploying Istio base (CRDs)..."
cd ..
nix build .#istio-base --out-link result-base
nix build .#istio-namespace-cluster-a --out-link result-ns-a
nix build .#istio-namespace-cluster-b --out-link result-ns-b

echo "  Deploying to ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" apply -f result-ns-a/manifest.yaml
kubectl --context="${CTX_CLUSTER1}" apply -f result-base/manifest.yaml --validate=false

echo "  Deploying to ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" apply -f result-ns-b/manifest.yaml
kubectl --context="${CTX_CLUSTER2}" apply -f result-base/manifest.yaml --validate=false

cd demo

##############################################################################
# Step 2: Deploy istiod (initial deployment without gateway addresses)
##############################################################################

echo ""
echo "Step 2: Deploying istiod (initial deployment)..."

cd ..
nix build .#istio-istiod-cluster-a --out-link result-istiod-a
nix build .#istio-istiod-cluster-b --out-link result-istiod-b

echo "  Deploying istiod to ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" apply -f result-istiod-a/manifest.yaml --validate=false

echo "  Deploying istiod to ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" apply -f result-istiod-b/manifest.yaml --validate=false

echo "  Waiting for istiod in ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

echo "  Waiting for istiod in ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

cd demo

##############################################################################
# Step 3: Deploy east-west gateways to both clusters
##############################################################################

echo ""
echo "Step 3: Deploying east-west gateways..."

echo "  Deploying to ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" apply -f - <<'EOF'
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
  labels:
    istio: eastwestgateway
    topology.istio.io/network: network1
spec:
  type: NodePort
  selector:
    istio: eastwestgateway
  ports:
  - port: 15021
    name: status-port
    protocol: TCP
    targetPort: 15021
    nodePort: 30021
  - port: 15443
    name: tls
    protocol: TCP
    targetPort: 15443
    nodePort: 30443
  - port: 15012
    name: tcp-istiod
    protocol: TCP
    targetPort: 15012
    nodePort: 30012
  - port: 15017
    name: tcp-webhook
    protocol: TCP
    targetPort: 15017
    nodePort: 30017
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
        topology.istio.io/network: network1
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-eastwestgateway
      containers:
      - name: istio-proxy
        image: docker.io/istio/proxyv2:1.24.2
        args:
        - proxy
        - router
        - --domain
        - $(POD_NAMESPACE).svc.cluster.local
        - --proxyLogLevel=warning
        - --proxyComponentLogLevel=misc:error
        - --log_output_level=default:info
        ports:
        - containerPort: 15021
          protocol: TCP
        - containerPort: 15443
          protocol: TCP
        - containerPort: 15012
          protocol: TCP
        - containerPort: 15017
          protocol: TCP
        env:
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
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: "network1"
        - name: ISTIO_META_DNS_CAPTURE
          value: "true"
        - name: ISTIO_META_DNS_AUTO_ALLOCATE
          value: "true"
        volumeMounts:
        - name: istio-envoy
          mountPath: /etc/istio/proxy
        - name: config-volume
          mountPath: /etc/istio/config
        - name: istio-data
          mountPath: /var/lib/istio/data
        - name: podinfo
          mountPath: /etc/istio/pod
        - name: istiod-ca-cert
          mountPath: /var/run/secrets/istio
      volumes:
      - name: istio-envoy
        emptyDir: {}
      - name: istio-data
        emptyDir: {}
      - name: podinfo
        downwardAPI:
          items:
          - path: "labels"
            fieldRef:
              fieldPath: metadata.labels
          - path: "annotations"
            fieldRef:
              fieldPath: metadata.annotations
      - name: config-volume
        configMap:
          name: istio
          optional: true
      - name: istiod-ca-cert
        configMap:
          name: istio-ca-root-cert
          optional: true
EOF

echo "  Deploying to ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" apply -f - <<'EOF'
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
  labels:
    istio: eastwestgateway
    topology.istio.io/network: network2
spec:
  type: NodePort
  selector:
    istio: eastwestgateway
  ports:
  - port: 15021
    name: status-port
    protocol: TCP
    targetPort: 15021
    nodePort: 30021
  - port: 15443
    name: tls
    protocol: TCP
    targetPort: 15443
    nodePort: 30443
  - port: 15012
    name: tcp-istiod
    protocol: TCP
    targetPort: 15012
    nodePort: 30012
  - port: 15017
    name: tcp-webhook
    protocol: TCP
    targetPort: 15017
    nodePort: 30017
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
        topology.istio.io/network: network2
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-eastwestgateway
      containers:
      - name: istio-proxy
        image: docker.io/istio/proxyv2:1.24.2
        args:
        - proxy
        - router
        - --domain
        - $(POD_NAMESPACE).svc.cluster.local
        - --proxyLogLevel=warning
        - --proxyComponentLogLevel=misc:error
        - --log_output_level=default:info
        ports:
        - containerPort: 15021
          protocol: TCP
        - containerPort: 15443
          protocol: TCP
        - containerPort: 15012
          protocol: TCP
        - containerPort: 15017
          protocol: TCP
        env:
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
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: "network2"
        - name: ISTIO_META_DNS_CAPTURE
          value: "true"
        - name: ISTIO_META_DNS_AUTO_ALLOCATE
          value: "true"
        volumeMounts:
        - name: istio-envoy
          mountPath: /etc/istio/proxy
        - name: config-volume
          mountPath: /etc/istio/config
        - name: istio-data
          mountPath: /var/lib/istio/data
        - name: podinfo
          mountPath: /etc/istio/pod
        - name: istiod-ca-cert
          mountPath: /var/run/secrets/istio
      volumes:
      - name: istio-envoy
        emptyDir: {}
      - name: istio-data
        emptyDir: {}
      - name: podinfo
        downwardAPI:
          items:
          - path: "labels"
            fieldRef:
              fieldPath: metadata.labels
          - path: "annotations"
            fieldRef:
              fieldPath: metadata.annotations
      - name: config-volume
        configMap:
          name: istio
          optional: true
      - name: istiod-ca-cert
        configMap:
          name: istio-ca-root-cert
          optional: true
EOF

echo "  Waiting for gateways to be ready..."
kubectl --context="${CTX_CLUSTER1}" wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system
kubectl --context="${CTX_CLUSTER2}" wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system

##############################################################################
# Step 4: Get gateway node IPs and patch services with externalIPs
##############################################################################

echo ""
echo "Step 4: Configuring gateway external IPs..."

# Get cluster-a API server IP on shared network
CLUSTER_A_API_IP=$(docker inspect k3d-cluster-a-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')
echo "  Cluster A API server IP: ${CLUSTER_A_API_IP}"

# Get cluster-b API server IP on shared network
CLUSTER_B_API_IP=$(docker inspect k3d-cluster-b-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')
echo "  Cluster B API server IP: ${CLUSTER_B_API_IP}"

# For cluster-a gateway, get all node IPs on the shared network
CLUSTER_A_NODE_IPS=$(docker network inspect k3d-multicluster | jq -r '.[] | .Containers | to_entries[] | select(.value.Name | startswith("k3d-cluster-a")) | .value.IPv4Address | split("/")[0]' | tr '\n' ',' | sed 's/,$//')
echo "  Cluster A node IPs: ${CLUSTER_A_NODE_IPS}"

# For cluster-b gateway, get all node IPs on the shared network
CLUSTER_B_NODE_IPS=$(docker network inspect k3d-multicluster | jq -r '.[] | .Containers | to_entries[] | select(.value.Name | startswith("k3d-cluster-b")) | .value.IPv4Address | split("/")[0]' | tr '\n' ',' | sed 's/,$//')
echo "  Cluster B node IPs: ${CLUSTER_B_NODE_IPS}"

# Convert to arrays for patching
IFS=',' read -ra CLUSTER_A_IPS_ARRAY <<< "$CLUSTER_A_NODE_IPS"
IFS=',' read -ra CLUSTER_B_IPS_ARRAY <<< "$CLUSTER_B_NODE_IPS"

# Build JSON array for cluster-a
CLUSTER_A_EXTERNAL_IPS_JSON=$(printf '%s\n' "${CLUSTER_A_IPS_ARRAY[@]}" | jq -R . | jq -s .)

# Build JSON array for cluster-b
CLUSTER_B_EXTERNAL_IPS_JSON=$(printf '%s\n' "${CLUSTER_B_IPS_ARRAY[@]}" | jq -R . | jq -s .)

# Patch the gateway services
echo "  Patching gateway service in ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" patch service istio-eastwestgateway -n istio-system -p "{\"spec\":{\"externalIPs\":${CLUSTER_A_EXTERNAL_IPS_JSON}}}"

echo "  Patching gateway service in ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" patch service istio-eastwestgateway -n istio-system -p "{\"spec\":{\"externalIPs\":${CLUSTER_B_EXTERNAL_IPS_JSON}}}"

# Use the first node IP as the gateway address for each network
GATEWAY_ADDRESS_NETWORK1="${CLUSTER_A_IPS_ARRAY[0]}"
GATEWAY_ADDRESS_NETWORK2="${CLUSTER_B_IPS_ARRAY[0]}"

echo "  Gateway address for network1: ${GATEWAY_ADDRESS_NETWORK1}"
echo "  Gateway address for network2: ${GATEWAY_ADDRESS_NETWORK2}"

##############################################################################
# Step 4: Build and deploy istiod with gateway addresses
##############################################################################

echo ""
echo "Step 4: Building and deploying istiod with gateway addresses..."

cd ..

# Build base istiod manifests with gateway addresses
echo "  Building istiod for cluster-a..."
nix build .#istio-istiod-cluster-a --out-link result-istiod-a

echo "  Building istiod for cluster-b..."
nix build .#istio-istiod-cluster-b --out-link result-istiod-b

# Patch the manifests with actual gateway IPs using yq
echo "  Patching manifests with gateway addresses..."
echo "    Network1 gateway: ${GATEWAY_ADDRESS_NETWORK1}"
echo "    Network2 gateway: ${GATEWAY_ADDRESS_NETWORK2}"

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "  ERROR: yq is required but not installed. Install with: brew install yq"
    exit 1
fi

echo "  Patching cluster-a manifest..."
yq eval '
  (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.mesh) |= (
    . | from_yaml |
    .meshNetworks.network1.gateways[0] = {"address": "'${GATEWAY_ADDRESS_NETWORK1}'", "port": 15443} |
    .meshNetworks.network2.gateways[0] = {"address": "'${GATEWAY_ADDRESS_NETWORK2}'", "port": 15443} |
    to_yaml
  ) |
  (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.meshNetworks) = (
    {"networks": {
      "network1": {
        "endpoints": [{"fromRegistry": "cluster-a"}],
        "gateways": [{"address": "'${GATEWAY_ADDRESS_NETWORK1}'", "port": 15443}]
      },
      "network2": {
        "endpoints": [{"fromRegistry": "cluster-b"}],
        "gateways": [{"address": "'${GATEWAY_ADDRESS_NETWORK2}'", "port": 15443}]
      }
    }} | to_yaml
  )
' result-istiod-a/manifest.yaml > /tmp/istiod-cluster-a-patched.yaml

echo "  Patching cluster-b manifest..."
yq eval '
  (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.mesh) |= (
    . | from_yaml |
    .meshNetworks.network1.gateways[0] = {"address": "'${GATEWAY_ADDRESS_NETWORK1}'", "port": 15443} |
    .meshNetworks.network2.gateways[0] = {"address": "'${GATEWAY_ADDRESS_NETWORK2}'", "port": 15443} |
    to_yaml
  ) |
  (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.meshNetworks) = (
    {"networks": {
      "network1": {
        "endpoints": [{"fromRegistry": "cluster-a"}],
        "gateways": [{"address": "'${GATEWAY_ADDRESS_NETWORK1}'", "port": 15443}]
      },
      "network2": {
        "endpoints": [{"fromRegistry": "cluster-b"}],
        "gateways": [{"address": "'${GATEWAY_ADDRESS_NETWORK2}'", "port": 15443}]
      }
    }} | to_yaml
  )
' result-istiod-b/manifest.yaml > /tmp/istiod-cluster-b-patched.yaml

echo "  Deploying istiod to ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" apply -f /tmp/istiod-cluster-a-patched.yaml --validate=false

echo "  Deploying istiod to ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" apply -f /tmp/istiod-cluster-b-patched.yaml --validate=false

cd demo

echo "  Waiting for istiod in ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

echo "  Waiting for istiod in ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

##############################################################################
# Step 5: Expose services via east-west gateway
##############################################################################

echo ""
echo "Step 5: Configuring east-west gateway routing..."

kubectl --context="${CTX_CLUSTER1}" apply -f - <<EOF
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

kubectl --context="${CTX_CLUSTER2}" apply -f - <<EOF
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

##############################################################################
# Step 6: Enable endpoint discovery (create remote secrets)
##############################################################################

echo ""
echo "Step 6: Creating remote secrets for endpoint discovery..."

echo "  Installing cluster-b secret in ${CTX_CLUSTER1}..."
istioctl create-remote-secret \
  --context="${CTX_CLUSTER2}" \
  --name=cluster-b \
  --server="https://${CLUSTER_B_API_IP}:6443" | \
  kubectl apply -f - --context="${CTX_CLUSTER1}"

echo "  Installing cluster-a secret in ${CTX_CLUSTER2}..."
istioctl create-remote-secret \
  --context="${CTX_CLUSTER1}" \
  --name=cluster-a \
  --server="https://${CLUSTER_A_API_IP}:6443" | \
  kubectl apply -f - --context="${CTX_CLUSTER2}"

# Wait for istiod to pick up the remote secrets
echo "  Waiting for cross-cluster endpoint discovery..."
sleep 10

# Restart istiod pods to ensure they pick up the new configuration
echo "  Restarting istiod pods..."
kubectl --context="${CTX_CLUSTER1}" rollout restart deployment/istiod -n istio-system
kubectl --context="${CTX_CLUSTER2}" rollout restart deployment/istiod -n istio-system

kubectl --context="${CTX_CLUSTER1}" rollout status deployment/istiod -n istio-system --timeout=120s
kubectl --context="${CTX_CLUSTER2}" rollout status deployment/istiod -n istio-system --timeout=120s

##############################################################################
# Step 7: Deploy demo services
##############################################################################

echo ""
echo "Step 7: Deploying hello service to ${CTX_CLUSTER1}..."

kubectl --context="${CTX_CLUSTER1}" create namespace demo 2>/dev/null || true
kubectl --context="${CTX_CLUSTER1}" label namespace demo istio-injection=enabled --overwrite

kubectl --context="${CTX_CLUSTER1}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: hello
  namespace: demo
  labels:
    app: hello
spec:
  ports:
  - port: 8080
    name: http
  clusterIP: None
  selector:
    app: hello
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
        image: docker.io/istio/examples-helloworld-v1:latest
        ports:
        - containerPort: 8080
        env:
        - name: SERVICE_VERSION
          value: "v1"
EOF

echo "  Waiting for hello pods..."
# Wait for StatefulSet to create at least one pod
for i in {1..30}; do
  POD_COUNT=$(kubectl --context="${CTX_CLUSTER1}" get pods -n demo -l app=hello --no-headers 2>/dev/null | wc -l)
  if [ "$POD_COUNT" -gt 0 ]; then
    break
  fi
  echo "    Waiting for StatefulSet to create pods... ($i/30)"
  sleep 2
done

# Now wait for pods to be ready
kubectl --context="${CTX_CLUSTER1}" wait --for=condition=ready --timeout=300s pod -l app=hello -n demo

echo ""
echo "Step 8: Creating demo-dr namespace in ${CTX_CLUSTER2}..."

kubectl --context="${CTX_CLUSTER2}" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: demo-dr
  labels:
    istio-injection: enabled
    topology.istio.io/network: network2
EOF

##############################################################################
# Deployment Complete
##############################################################################

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Gateway addresses configured:"
echo "  network1 (cluster-a): ${GATEWAY_ADDRESS_NETWORK1}:15443"
echo "  network2 (cluster-b): ${GATEWAY_ADDRESS_NETWORK2}:15443"
echo ""
echo "Run ./test.sh to verify cross-cluster connectivity"
echo ""

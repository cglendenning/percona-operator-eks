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

# Build Istio manifests for both clusters
echo "Step 1: Building Istio manifests with Nix..."
cd ..
echo "  Building manifests for cluster-a..."
nix build .#istio-cluster-a --out-link result-cluster-a
echo "  Building manifests for cluster-b..."
nix build .#istio-cluster-b --out-link result-cluster-b
cd demo

##############################################################################
# Configure Cluster 1
##############################################################################

echo ""
echo "Step 2: Configuring Cluster 1 (${CTX_CLUSTER1})..."

# Set network label for istio-system namespace
kubectl --context="${CTX_CLUSTER1}" create namespace istio-system 2>/dev/null || true
kubectl --context="${CTX_CLUSTER1}" label namespace istio-system topology.istio.io/network=network1 --overwrite

# Deploy Istio to cluster-a with multi-cluster config
echo "  Deploying Istio to ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" apply -f ../result-cluster-a/manifest.yaml --validate=false

# Wait for istiod deployment
echo "  Waiting for istiod in ${CTX_CLUSTER1}..."
kubectl --context="${CTX_CLUSTER1}" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

##############################################################################
# Install East-West Gateway in Cluster 1
##############################################################################

echo ""
echo "Step 3: Installing east-west gateway in ${CTX_CLUSTER1}..."

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
        service.istio.io/canonical-name: istio-eastwestgateway
        service.istio.io/canonical-revision: latest
        topology.istio.io/network: network1
      annotations:
        sidecar.istio.io/inject: "false"
        prometheus.io/port: "15020"
        prometheus.io/scrape: "true"
        prometheus.io/path: "/stats/prometheus"
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
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: network1
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
        - containerPort: 15021
          protocol: TCP
        - containerPort: 15443
          protocol: TCP
        - containerPort: 15012
          protocol: TCP
        - containerPort: 15017
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
        - mountPath: /var/lib/istio/data
          name: istio-data
        - mountPath: /etc/istio/pod
          name: podinfo
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
      - name: podinfo
        downwardAPI:
          items:
          - path: "labels"
            fieldRef:
              fieldPath: metadata.labels
          - path: "annotations"
            fieldRef:
              fieldPath: metadata.annotations
      - name: istio-data
        emptyDir: {}
      - name: istio-token
        projected:
          sources:
          - serviceAccountToken:
              audience: istio-ca
              expirationSeconds: 43200
              path: istio-token
EOF

echo "  Waiting for east-west gateway..."
kubectl --context="${CTX_CLUSTER1}" wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system

##############################################################################
# Expose Services in Cluster 1
##############################################################################

echo ""
echo "Step 4: Exposing services in ${CTX_CLUSTER1}..."

kubectl --context="${CTX_CLUSTER1}" apply -n istio-system -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: cross-network-gateway
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
# Configure Cluster 2
##############################################################################

echo ""
echo "Step 5: Configuring Cluster 2 (${CTX_CLUSTER2})..."

# Set network label for istio-system namespace
kubectl --context="${CTX_CLUSTER2}" create namespace istio-system 2>/dev/null || true
kubectl --context="${CTX_CLUSTER2}" label namespace istio-system topology.istio.io/network=network2 --overwrite

# Deploy Istio to cluster-b with multi-cluster config
echo "  Deploying Istio to ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" apply -f ../result-cluster-b/manifest.yaml --validate=false

# Wait for istiod deployment
echo "  Waiting for istiod in ${CTX_CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

##############################################################################
# Install East-West Gateway in Cluster 2
##############################################################################

echo ""
echo "Step 6: Installing east-west gateway in ${CTX_CLUSTER2}..."

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
    nodePort: 31021
  - port: 15443
    name: tls
    protocol: TCP
    targetPort: 15443
    nodePort: 31443
  - port: 15012
    name: tcp-istiod
    protocol: TCP
    targetPort: 15012
    nodePort: 31012
  - port: 15017
    name: tcp-webhook
    protocol: TCP
    targetPort: 15017
    nodePort: 31017
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
        topology.istio.io/network: network2
      annotations:
        sidecar.istio.io/inject: "false"
        prometheus.io/port: "15020"
        prometheus.io/scrape: "true"
        prometheus.io/path: "/stats/prometheus"
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
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: network2
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
        - containerPort: 15021
          protocol: TCP
        - containerPort: 15443
          protocol: TCP
        - containerPort: 15012
          protocol: TCP
        - containerPort: 15017
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
        - mountPath: /var/lib/istio/data
          name: istio-data
        - mountPath: /etc/istio/pod
          name: podinfo
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
      - name: podinfo
        downwardAPI:
          items:
          - path: "labels"
            fieldRef:
              fieldPath: metadata.labels
          - path: "annotations"
            fieldRef:
              fieldPath: metadata.annotations
      - name: istio-data
        emptyDir: {}
      - name: istio-token
        projected:
          sources:
          - serviceAccountToken:
              audience: istio-ca
              expirationSeconds: 43200
              path: istio-token
EOF

echo "  Waiting for east-west gateway..."
kubectl --context="${CTX_CLUSTER2}" wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system

##############################################################################
# Expose Services in Cluster 2
##############################################################################

echo ""
echo "Step 7: Exposing services in ${CTX_CLUSTER2}..."

kubectl --context="${CTX_CLUSTER2}" apply -n istio-system -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: cross-network-gateway
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
# Verify Shared Network Connection
##############################################################################

echo ""
echo "Step 8: Verifying shared network connectivity..."
# setup-clusters.sh already connected clusters, but verify/reconnect if needed
docker network create k3d-shared 2>/dev/null || true

for node in $(docker ps --format '{{.Names}}' | grep -E 'k3d-cluster-[ab]'); do
  docker network connect k3d-shared $node 2>/dev/null || true
done

echo "Shared network verified"

##############################################################################
# Enable Endpoint Discovery (THE KEY STEP)
##############################################################################

echo ""
echo "Step 9: Enabling endpoint discovery (remote secrets)..."

# For k3d, we need to use the API server's IP on the shared network
# Get the k3d server container IPs on the k3d-shared network
CLUSTER_A_API_IP=$(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-shared -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
CLUSTER_B_API_IP=$(docker inspect k3d-cluster-b-server-0 -f '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect k3d-shared -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')

echo "  Cluster A API server IP on shared network: ${CLUSTER_A_API_IP}"
echo "  Cluster B API server IP on shared network: ${CLUSTER_B_API_IP}"

# Install remote secret in cluster2 for accessing cluster1
echo "  Creating remote secret for ${CTX_CLUSTER1} in ${CTX_CLUSTER2}..."
istioctl create-remote-secret \
  --context="${CTX_CLUSTER1}" \
  --name=cluster-a \
  --server="https://${CLUSTER_A_API_IP}:6443" | \
  kubectl apply -f - --context="${CTX_CLUSTER2}"

# Install remote secret in cluster1 for accessing cluster2
echo "  Creating remote secret for ${CTX_CLUSTER2} in ${CTX_CLUSTER1}..."
istioctl create-remote-secret \
  --context="${CTX_CLUSTER2}" \
  --name=cluster-b \
  --server="https://${CLUSTER_B_API_IP}:6443" | \
  kubectl apply -f - --context="${CTX_CLUSTER1}"

##############################################################################
# Deploy Hello Service to Cluster 1
##############################################################################

echo ""
echo "Step 10: Deploying hello service to ${CTX_CLUSTER1}..."

kubectl --context="${CTX_CLUSTER1}" apply -f - <<'EOF'
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

echo "  Waiting for hello pods..."
sleep 10
kubectl wait --for=condition=ready pod -l app=hello -n demo --timeout=120s --context="${CTX_CLUSTER1}" || true

##############################################################################
# Create Test Namespace in Cluster 2
##############################################################################

echo ""
echo "Step 11: Creating demo-dr namespace in ${CTX_CLUSTER2}..."

kubectl --context="${CTX_CLUSTER2}" apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo-dr
      labels:
    istio-injection: enabled
EOF

##############################################################################
# Completion
##############################################################################

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "✓ Istio deployed to both clusters with multi-primary configuration"
echo "✓ East-west gateways installed in both clusters"
echo "✓ Endpoint discovery enabled (remote secrets created)"
echo "✓ Hello service deployed to ${CTX_CLUSTER1}"
echo "✓ Test namespace created in ${CTX_CLUSTER2}"
echo ""
echo "Key Differences from Manual Approach:"
echo "  - Endpoint discovery: Clusters share Kubernetes API access"
echo "  - NO manual ServiceEntry needed"
echo "  - Envoy DNS proxy: Intercepts DNS queries automatically"
echo "  - Standard Kubernetes DNS names work: hello.demo.svc.cluster.local"
echo ""
echo "Verify with:"
echo "  ./test.sh"
echo ""
echo "Check Istio multi-cluster status:"
echo "  istioctl proxy-status --context ${CTX_CLUSTER1}"
echo "  istioctl proxy-status --context ${CTX_CLUSTER2}"

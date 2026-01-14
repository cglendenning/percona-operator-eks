#!/usr/bin/env bash
set -euo pipefail

echo "=== Fixing East-West Gateway RBAC ==="
echo ""

# Create RBAC for east-west gateway in both clusters
for CONTEXT in k3d-cluster-a k3d-cluster-b; do
  echo "Fixing RBAC in $CONTEXT..."
  
  # ClusterRole for gateway
  kubectl apply --context=$CONTEXT -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-eastwestgateway
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "services", "endpoints"]
  verbs: ["get", "watch", "list"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["create"]
EOF

  # ClusterRoleBinding
  kubectl apply --context=$CONTEXT -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-eastwestgateway
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-eastwestgateway
subjects:
- kind: ServiceAccount
  name: istio-eastwestgateway
  namespace: istio-system
EOF

  echo "RBAC fixed in $CONTEXT"
  echo ""
done

echo "Restarting east-west gateways..."
kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=k3d-cluster-a
kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=k3d-cluster-b

echo "Waiting for restart..."
kubectl rollout status deployment/istio-eastwestgateway -n istio-system --context=k3d-cluster-a --timeout=60s
kubectl rollout status deployment/istio-eastwestgateway -n istio-system --context=k3d-cluster-b --timeout=60s

echo ""
echo "=== RBAC fixed! Check logs ==="
echo "kubectl logs -n istio-system deployment/istio-eastwestgateway --context=k3d-cluster-a --tail=10"

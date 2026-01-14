#!/usr/bin/env bash
set -euo pipefail

echo "=== Adding JWT token volume to east-west gateway ==="
echo ""

for CONTEXT in k3d-cluster-a k3d-cluster-b; do
  echo "Patching gateway deployment in $CONTEXT..."
  
  # Patch deployment to add token volume
  kubectl patch deployment istio-eastwestgateway -n istio-system --context=$CONTEXT --type='json' -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {
        "name": "istio-token",
        "projected": {
          "sources": [
            {
              "serviceAccountToken": {
                "audience": "istio-ca",
                "expirationSeconds": 43200,
                "path": "istio-token"
              }
            }
          ]
        }
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {
        "mountPath": "/var/run/secrets/tokens",
        "name": "istio-token"
      }
    }
  ]'
  
  echo "Patched $CONTEXT"
done

echo ""
echo "Waiting for rollout..."
kubectl rollout status deployment/istio-eastwestgateway -n istio-system --context=k3d-cluster-a --timeout=60s
kubectl rollout status deployment/istio-eastwestgateway -n istio-system --context=k3d-cluster-b --timeout=60s

echo ""
echo "Checking logs..."
sleep 5
kubectl logs -n istio-system deployment/istio-eastwestgateway --context=k3d-cluster-a --tail=10

echo ""
echo "=== Token volume added! ==="

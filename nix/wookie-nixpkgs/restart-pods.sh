#!/usr/bin/env bash
set -euo pipefail

echo "=== Restarting pods to pick up new Istio config ==="
echo ""

echo "Restarting helloworld in cluster-a..."
kubectl rollout restart deployment/helloworld-v1 -n demo --context=k3d-cluster-a
kubectl rollout status deployment/helloworld-v1 -n demo --context=k3d-cluster-a --timeout=60s

echo ""
echo "Deleting test pod in cluster-b (will be recreated by test)..."
kubectl delete pod test-pod -n wookie-dr --context=k3d-cluster-b || true

echo ""
echo "=== Pods restarted ==="
echo ""
echo "Wait 10 seconds for config sync, then run: nix run .#test"

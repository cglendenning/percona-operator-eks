#!/usr/bin/env bash

echo "=== Checking mTLS configuration ==="
echo ""

kubectl exec test-pod -n wookie-dr -c istio-proxy --context=k3d-cluster-b -- \
  curl -s localhost:15000/config_dump | jq '.configs[] | select(."@type" == "type.googleapis.com/envoy.admin.v3.ClustersConfigDump") | .dynamic_active_clusters[] | select(.cluster.name | contains("helloworld")) | .cluster.transport_socket' | head -50

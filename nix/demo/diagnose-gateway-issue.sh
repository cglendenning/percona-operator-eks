#!/bin/bash

echo "=== Gateway Deployment Status ==="
kubectl get deployment istio-eastwestgateway -n istio-system --context k3d-cluster-a

echo ""
echo "=== Gateway Pods ==="
kubectl get pods -n istio-system -l istio=eastwestgateway --context k3d-cluster-a

echo ""
echo "=== Gateway Pod Events ==="
kubectl get events -n istio-system --sort-by='.lastTimestamp' --context k3d-cluster-a | tail -20

echo ""
echo "=== Check if ServiceAccount exists ==="
kubectl get serviceaccount istio-ingressgateway-service-account -n istio-system --context k3d-cluster-a 2>&1

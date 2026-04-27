#!/usr/bin/env bash
# Ensure a working k3d cluster + merged kubeconfig so kubectl (and port-forward) do not hang
# on TLS handshake / connection refused (common after Colima restarts or stale kubeconfig).
# Default cluster name matches k3d-reload-controller.sh.
set -euo pipefail

CLUSTER="${K3D_CLUSTER:-pmm-local}"
CTX="k3d-${CLUSTER}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need docker
need k3d
need kubectl

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not reachable. Start it (e.g. macOS+Colima: colima start) and retry." >&2
  exit 1
fi

if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; then
  k3d cluster start "$CLUSTER" --wait
else
  echo "[pmm-k3d-ensure] creating k3d cluster ${CLUSTER} (first run)"
  k3d cluster create "$CLUSTER" --wait
fi

echo "[pmm-k3d-ensure] merging kubeconfig and switching context to ${CTX}"
k3d kubeconfig merge "$CLUSTER" --kubeconfig-merge-default --kubeconfig-switch-context

if ! kubectl --request-timeout=15s --context "$CTX" cluster-info >/dev/null; then
  echo "[pmm-k3d-ensure] kubectl still cannot reach the API. Try: k3d cluster delete ${CLUSTER} && $0" >&2
  exit 1
fi

echo "[pmm-k3d-ensure] ok (context: ${CTX})"

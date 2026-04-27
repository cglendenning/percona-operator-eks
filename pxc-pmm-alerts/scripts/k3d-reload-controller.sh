#!/usr/bin/env bash
# Build controller image, import into k3d, apply Nix manifest, restart Deployment.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${K3D_CLUSTER:-pmm-local}"
NS="${PMM_NS:-pmm}"
IMG="pxc-pmm-alerts-controller:latest"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need docker
need k3d
need kubectl
need nix-build

cd "$ROOT"
docker build -t "$IMG" .
k3d image import "$IMG" -c "$CLUSTER"
MAN="$(nix-build pxc-pmm-alerts.nix -A k8sManifest --no-out-link)"
kubectl apply -f "$MAN" --request-timeout=30s
kubectl -n "$NS" rollout restart deployment/pxc-pmm-alerts-controller --request-timeout=10s 2>/dev/null || true
kubectl -n "$NS" rollout status deployment/pxc-pmm-alerts-controller --timeout=90s --request-timeout=10s
echo "Logs: kubectl -n $NS logs -f deploy/pxc-pmm-alerts-controller"

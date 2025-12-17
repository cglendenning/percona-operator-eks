#!/bin/bash
#
# Render Kubernetes manifests using Nix
#
# Usage:
#   ./render.sh                    # Render with default config
#   ./render.sh --registry ghcr.io/myorg --tag v1.0.0
#   ./render.sh --nodeport 30080   # Use NodePort service
#
# Output: manifests.yaml in the current directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
REGISTRY=""
IMAGE_TAG="latest"
NAMESPACE="default"
SERVICE_TYPE="ClusterIP"
NODE_PORT=""
OUTPUT_FILE="manifests.yaml"
INGRESS_ENABLED="true"
INGRESS_HOST="wookie.eko.dev.cookie.com"
INGRESS_CLASS=""
INGRESS_TLS="false"
INGRESS_TLS_SECRET="dr-dashboard-tls"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --nodeport)
            SERVICE_TYPE="NodePort"
            NODE_PORT="$2"
            shift 2
            ;;
        --loadbalancer)
            SERVICE_TYPE="LoadBalancer"
            shift
            ;;
        --ingress-host)
            INGRESS_HOST="$2"
            shift 2
            ;;
        --ingress-class)
            INGRESS_CLASS="$2"
            shift 2
            ;;
        --ingress-tls)
            INGRESS_TLS="true"
            shift
            ;;
        --ingress-tls-secret)
            INGRESS_TLS_SECRET="$2"
            shift 2
            ;;
        --no-ingress)
            INGRESS_ENABLED="false"
            shift
            ;;
        --output|-o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --registry REGISTRY       Container registry (e.g., ghcr.io/myorg)"
            echo "  --tag TAG                 Image tag (default: latest)"
            echo "  --namespace NS            Kubernetes namespace (default: default)"
            echo "  --nodeport PORT           Use NodePort service with specified port"
            echo "  --loadbalancer            Use LoadBalancer service"
            echo "  --ingress-host HOST       Ingress hostname (default: wookie.eko.dev.cookie.com)"
            echo "  --ingress-class CLASS     Ingress class name (e.g., nginx)"
            echo "  --ingress-tls             Enable TLS for ingress"
            echo "  --ingress-tls-secret NAME TLS secret name (default: dr-dashboard-tls)"
            echo "  --no-ingress              Disable ingress"
            echo "  --output, -o FILE         Output file (default: manifests.yaml)"
            echo "  --help, -h                Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for nix
if ! command -v nix &> /dev/null; then
    echo "ERROR: nix is not installed"
    echo "Install from: https://nixos.org/download.html"
    exit 1
fi

echo "Rendering DR Dashboard manifests..."
echo "  Registry: ${REGISTRY:-<local>}"
echo "  Tag: $IMAGE_TAG"
echo "  Namespace: $NAMESPACE"
echo "  Service Type: $SERVICE_TYPE"
if [ -n "$NODE_PORT" ]; then
    echo "  NodePort: $NODE_PORT"
fi
if [ "$INGRESS_ENABLED" = "true" ]; then
    echo "  Ingress Host: $INGRESS_HOST"
    if [ -n "$INGRESS_CLASS" ]; then
        echo "  Ingress Class: $INGRESS_CLASS"
    fi
    if [ "$INGRESS_TLS" = "true" ]; then
        echo "  Ingress TLS: enabled (secret: $INGRESS_TLS_SECRET)"
    fi
else
    echo "  Ingress: disabled"
fi

# Build nix expression for custom config
NIX_EXPR="(builtins.getFlake \"path:$SCRIPT_DIR\").lib.$(nix eval --impure --raw --expr 'builtins.currentSystem').generateManifests { registry = \"$REGISTRY\"; imageTag = \"$IMAGE_TAG\"; namespace = \"$NAMESPACE\"; serviceType = \"$SERVICE_TYPE\";"
if [ -n "$NODE_PORT" ]; then
    NIX_EXPR="$NIX_EXPR nodePort = $NODE_PORT;"
fi
NIX_EXPR="$NIX_EXPR ingressEnabled = $INGRESS_ENABLED; ingressHost = \"$INGRESS_HOST\";"
if [ -n "$INGRESS_CLASS" ]; then
    NIX_EXPR="$NIX_EXPR ingressClassName = \"$INGRESS_CLASS\";"
fi
NIX_EXPR="$NIX_EXPR ingressTlsEnabled = $INGRESS_TLS; ingressTlsSecretName = \"$INGRESS_TLS_SECRET\";"
NIX_EXPR="$NIX_EXPR }"

# Generate manifests
nix eval --impure --raw --expr "$NIX_EXPR" > "$OUTPUT_FILE"

echo ""
echo "Manifests written to: $OUTPUT_FILE"
echo ""
echo "Deploy with:"
echo "  kubectl apply -f $OUTPUT_FILE"


#!/bin/bash
set -e

# Setup LitmusChaos experiments and RBAC
# This script installs the necessary components for running chaos experiments

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Check if running under WSL
        if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LITMUS_NAMESPACE="litmus"
TARGET_NAMESPACE="percona"

echo "Setting up LitmusChaos experiments and RBAC..."

# Create service account for chaos experiments
echo "Creating litmus-admin service account..."
kubectl create serviceaccount litmus-admin -n ${LITMUS_NAMESPACE} 2>/dev/null || echo "Service account already exists"

# Create ClusterRole with necessary permissions
echo "Creating ClusterRole for chaos experiments..."
CLUSTERROLE_TEMPLATE="${SCRIPT_DIR}/templates/litmuschaos/litmus-admin-clusterrole.yaml"
if [ -f "$CLUSTERROLE_TEMPLATE" ]; then
    kubectl apply -f "$CLUSTERROLE_TEMPLATE"
else
    echo "Error: Template not found at $CLUSTERROLE_TEMPLATE"
    exit 1
fi

# Create ClusterRoleBinding
echo "Creating ClusterRoleBinding..."
CLUSTERROLEBINDING_TEMPLATE="${SCRIPT_DIR}/templates/litmuschaos/litmus-admin-clusterrolebinding.yaml"
if [ -f "$CLUSTERROLEBINDING_TEMPLATE" ]; then
    sed "s/{{NAMESPACE}}/${LITMUS_NAMESPACE}/g" "$CLUSTERROLEBINDING_TEMPLATE" | kubectl apply -f -
else
    echo "Error: Template not found at $CLUSTERROLEBINDING_TEMPLATE"
    exit 1
fi

# Install pod-delete ChaosExperiment
echo "Installing pod-delete ChaosExperiment..."
CHAOSEXPERIMENT_TEMPLATE="${SCRIPT_DIR}/templates/litmuschaos/pod-delete-chaosexperiment.yaml"
if [ -f "$CHAOSEXPERIMENT_TEMPLATE" ]; then
    sed "s/{{NAMESPACE}}/${LITMUS_NAMESPACE}/g" "$CHAOSEXPERIMENT_TEMPLATE" | kubectl apply -f -
else
    echo "Error: Template not found at $CHAOSEXPERIMENT_TEMPLATE"
    exit 1
fi

# Install chaos-operator
echo "Installing chaos-operator..."
OPERATOR_TEMPLATE="${SCRIPT_DIR}/templates/litmuschaos/litmus-operator.yaml"
if [ -f "$OPERATOR_TEMPLATE" ]; then
    kubectl apply -f "$OPERATOR_TEMPLATE"
else
    echo "Error: Template not found at $OPERATOR_TEMPLATE"
    exit 1
fi

# Wait for operator to be ready
echo "Waiting for chaos-operator to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/chaos-operator-ce -n ${LITMUS_NAMESPACE}

echo ""
echo "✓ LitmusChaos experiments and RBAC setup complete!"
echo ""
echo "Verifying installation..."
kubectl get serviceaccount litmus-admin -n ${LITMUS_NAMESPACE}
kubectl get chaosexperiments -n ${LITMUS_NAMESPACE}
kubectl get deployment chaos-operator-ce -n ${LITMUS_NAMESPACE}
echo ""
echo "✅ Setup complete! You can now run resiliency tests."


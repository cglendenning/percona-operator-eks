#!/bin/bash
set -e

# Setup LitmusChaos experiments and RBAC
# This script installs the necessary components for running chaos experiments

LITMUS_NAMESPACE="litmus"
TARGET_NAMESPACE="percona"

echo "Setting up LitmusChaos experiments and RBAC..."

# Create service account for chaos experiments
echo "Creating litmus-admin service account..."
kubectl create serviceaccount litmus-admin -n ${LITMUS_NAMESPACE} 2>/dev/null || echo "Service account already exists"

# Create ClusterRole with necessary permissions
echo "Creating ClusterRole for chaos experiments..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: litmus-admin
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/exec", "events", "replicationcontrollers"]
  verbs: ["create", "delete", "get", "list", "patch", "update", "deletecollection"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "replicasets", "daemonsets"]
  verbs: ["create", "delete", "get", "list", "patch", "update"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["create", "delete", "get", "list", "patch", "update", "deletecollection"]
- apiGroups: ["litmuschaos.io"]
  resources: ["chaosengines", "chaosexperiments", "chaosresults"]
  verbs: ["create", "delete", "get", "list", "patch", "update"]
EOF

# Create ClusterRoleBinding
echo "Creating ClusterRoleBinding..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: litmus-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: litmus-admin
subjects:
- kind: ServiceAccount
  name: litmus-admin
  namespace: ${LITMUS_NAMESPACE}
EOF

# Install pod-delete ChaosExperiment
echo "Installing pod-delete ChaosExperiment..."
cat <<EOF | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosExperiment
metadata:
  name: pod-delete
  namespace: ${LITMUS_NAMESPACE}
  labels:
    name: pod-delete
    app.kubernetes.io/part-of: litmus
    app.kubernetes.io/component: chaosexperiment
    app.kubernetes.io/version: latest
spec:
  definition:
    scope: Namespaced
    permissions:
      - apiGroups:
          - ""
        resources:
          - pods
        verbs:
          - create
          - delete
          - get
          - list
          - patch
          - update
          - deletecollection
      - apiGroups:
          - ""
        resources:
          - events
        verbs:
          - create
          - get
          - list
          - patch
          - update
      - apiGroups:
          - ""
        resources:
          - pods/log
        verbs:
          - get
          - list
          - watch
      - apiGroups:
          - ""
        resources:
          - pods/exec
        verbs:
          - get
          - list
          - create
      - apiGroups:
          - apps
        resources:
          - deployments
          - statefulsets
          - replicasets
          - daemonsets
        verbs:
          - list
          - get
      - apiGroups:
          - apps.openshift.io
        resources:
          - deploymentconfigs
        verbs:
          - list
          - get
      - apiGroups:
          - ""
        resources:
          - replicationcontrollers
        verbs:
          - get
          - list
      - apiGroups:
          - argoproj.io
        resources:
          - rollouts
        verbs:
          - list
          - get
      - apiGroups:
          - batch
        resources:
          - jobs
        verbs:
          - create
          - list
          - get
          - delete
          - deletecollection
      - apiGroups:
          - litmuschaos.io
        resources:
          - chaosengines
          - chaosexperiments
          - chaosresults
        verbs:
          - create
          - list
          - get
          - patch
          - update
          - delete
    image: "litmuschaos/go-runner:latest"
    imagePullPolicy: Always
    args:
      - -c
      - ./experiments -name pod-delete
    command:
      - /bin/bash
    env:
      - name: TOTAL_CHAOS_DURATION
        value: "15"
      - name: RAMP_TIME
        value: ""
      - name: FORCE
        value: "true"
      - name: CHAOS_INTERVAL
        value: "5"
      - name: PODS_AFFECTED_PERC
        value: ""
      - name: TARGET_CONTAINER
        value: ""
      - name: TARGET_PODS
        value: ""
      - name: NODE_LABEL
        value: ""
      - name: SEQUENCE
        value: "parallel"
    labels:
      name: pod-delete
      app.kubernetes.io/part-of: litmus
      app.kubernetes.io/component: experiment-job
      app.kubernetes.io/version: latest
EOF

# Install chaos-operator
echo "Installing chaos-operator..."
kubectl apply -f /Users/craig/percona_operator/litmus-operator.yaml

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

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litmus-operator
  namespace: litmus
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: litmus-operator
rules:
  - apiGroups: [""]
    resources: ["replicationcontrollers","secrets","pods","pods/exec","pods/log","pods/eviction","events","services"]
    verbs: ["create","get","list","update","patch","delete","deletecollection"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create","get","list","deletecollection","delete"]
  - apiGroups: ["apps"]
    resources: ["deployments","daemonsets","replicasets","statefulsets"]
    verbs: ["get","list"]
  - apiGroups: ["litmuschaos.io"]
    resources: ["chaosengines","chaosexperiments","chaosresults"]
    verbs: ["create","get","list","update","patch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: litmus-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: litmus-operator
subjects:
  - kind: ServiceAccount
    name: litmus-operator
    namespace: litmus
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chaos-operator-ce
  namespace: litmus
spec:
  replicas: 1
  selector:
    matchLabels:
      name: chaos-operator
  template:
    metadata:
      labels:
        name: chaos-operator
    spec:
      serviceAccountName: litmus-operator
      containers:
        - name: chaos-operator
          image: litmuschaos/chaos-operator:latest
          command:
            - chaos-operator
          imagePullPolicy: Always
          env:
            - name: CHAOS_RUNNER_IMAGE
              value: "litmuschaos/chaos-runner:latest"
            - name: WATCH_NAMESPACE
              value: ""
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: OPERATOR_NAME
              value: "chaos-operator"


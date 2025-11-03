# Setting Up an Internal Helm Chart Repository for EKS

This guide explains how to set up an internal Helm chart repository in your AWS EKS environment and configure your codebase to use it instead of external repositories.

## Current External Helm Repositories

Your codebase currently uses these external Helm repositories:

1. **Percona**: `https://percona.github.io/percona-helm-charts/`
   - Used in: `src/percona.ts` (line 10, 440, 451)
   - Charts: `percona/pxc-operator`, `percona/pxc-db`

2. **MinIO**: `https://charts.min.io/`
   - Used in: `src/percona.ts` (line 644, 650)
   - Chart: `minio/minio`

3. **LitmusChaos**: `https://litmuschaos.github.io/litmus-helm/`
   - Used in: `src/percona.ts` (line 1724), `install-litmus.sh` (line 67)
   - Chart: `litmuschaos/litmus`

## Recommended Solution: ChartMuseum

**ChartMuseum** is the recommended open-source solution for Helm chart repositories because:

- ✅ **Helm-specific**: Designed specifically for Helm charts
- ✅ **Lightweight**: Minimal resource footprint
- ✅ **S3 Support**: Native AWS S3 backend support
- ✅ **Kubernetes-native**: Can run in your EKS cluster
- ✅ **Simple API**: Easy to use and integrate
- ✅ **No license costs**: Fully open source

### Alternative Options

1. **Nexus Repository Manager**: More feature-rich but heavier and more complex
2. **Harbor**: Container registry with Helm support, but overkill if you only need Helm charts
3. **Artifactory**: Not open-source (free tier available but limited)

## Architecture Overview

```
┌─────────────────┐
│  EKS Cluster    │
│                 │
│  ┌───────────┐  │
│  │ChartMuseum│  │───┐
│  │  Pod      │  │   │
│  └───────────┘  │   │
│        │        │   │
│  ┌─────▼────┐   │   │
│  │  S3      │   │   │
│  │  Bucket  │◄──┘   │
│  └──────────┘       │
│                     │
│  ┌──────────────┐   │
│  │  Your Apps   │───┘
│  │  (Percona)   │
│  └──────────────┘
│
└─────────────────┘
```

## Step-by-Step Setup Guide

### Step 1: Create S3 Bucket for Chart Storage

```bash
# Set variables
export AWS_REGION="us-east-1"
export CHART_BUCKET_NAME="percona-helm-charts-$(date +%s)"
export NAMESPACE="chartmuseum"

# Create S3 bucket
aws s3 mb s3://${CHART_BUCKET_NAME} --region ${AWS_REGION}

# Enable versioning (optional but recommended)
aws s3api put-bucket-versioning \
    --bucket ${CHART_BUCKET_NAME} \
    --versioning-configuration Status=Enabled

# Block public access (security best practice)
aws s3api put-public-access-block \
    --bucket ${CHART_BUCKET_NAME} \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### Step 2: Create IAM Role for ChartMuseum (IRSA)

Create an IAM role that ChartMuseum can assume to access S3:

```bash
# Create IAM policy for S3 access
cat > /tmp/chartmuseum-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${CHART_BUCKET_NAME}",
        "arn:aws:s3:::${CHART_BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF

# Create the policy
aws iam create-policy \
    --policy-name ChartMuseumS3Policy \
    --policy-document file:///tmp/chartmuseum-s3-policy.json

# Note the Policy ARN for next step
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='ChartMuseumS3Policy'].Arn" --output text)

# Create IAM role for service account (replace with your cluster OIDC provider)
# First, get your cluster OIDC provider
CLUSTER_NAME="percona-eks"
OIDC_PROVIDER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

# Create trust policy
cat > /tmp/chartmuseum-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:chartmuseum",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create the role
aws iam create-role \
    --role-name ChartMuseumRole \
    --assume-role-policy-document file:///tmp/chartmuseum-trust-policy.json

# Attach the policy
aws iam attach-role-policy \
    --role-name ChartMuseumRole \
    --policy-arn ${POLICY_ARN}

# Get the role ARN
ROLE_ARN=$(aws iam get-role --role-name ChartMuseumRole --query 'Role.Arn' --output text)
```

### Step 3: Install ChartMuseum via Helm

```bash
# Add ChartMuseum Helm repo (one last time from external!)
helm repo add chartmuseum https://chartmuseum.github.io/charts
helm repo update

# Create namespace
kubectl create namespace ${NAMESPACE}

# Create service account with IRSA annotation
kubectl create serviceaccount chartmuseum -n ${NAMESPACE}
kubectl annotate serviceaccount chartmuseum \
    -n ${NAMESPACE} \
    eks.amazonaws.com/role-arn=${ROLE_ARN}

# Install ChartMuseum
helm install chartmuseum chartmuseum/chartmuseum \
    --namespace ${NAMESPACE} \
    --set env.open.DISABLE_API=false \
    --set env.open.STORAGE=amazon \
    --set env.open.STORAGE_AMAZON_BUCKET=${CHART_BUCKET_NAME} \
    --set env.open.STORAGE_AMAZON_REGION=${AWS_REGION} \
    --set serviceAccount.name=chartmuseum \
    --set service.type=LoadBalancer \
    --wait

# Get the service endpoint
kubectl get svc chartmuseum -n ${NAMESPACE}
```

### Step 4: Configure ChartMuseum URL

After ChartMuseum is deployed, get its URL:

```bash
# If using LoadBalancer, get the external endpoint
CHARTMUSEUM_URL=$(kubectl get svc chartmuseum -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Or if using ClusterIP/Ingress, use that instead
# CHARTMUSEUM_URL="chartmuseum.${NAMESPACE}.svc.cluster.local"

# Add to your local Helm config (for testing)
helm repo add internal http://${CHARTMUSEUM_URL}
helm repo update
```

### Step 5: Mirror External Charts to ChartMuseum

You'll need to download charts from external repos and upload them to ChartMuseum:

```bash
# Install helm-push plugin if not already installed
helm plugin install https://github.com/chartmuseum/helm-push.git

# Create temporary directory
mkdir -p /tmp/chart-mirror
cd /tmp/chart-mirror

# Download Percona charts
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
helm pull percona/pxc-operator
helm pull percona/pxc-db

# Download MinIO chart
helm repo add minio https://charts.min.io/
helm repo update
helm pull minio/minio

# Download LitmusChaos chart
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update
helm pull litmuschaos/litmus

# Push all charts to ChartMuseum
for chart in *.tgz; do
    echo "Pushing $chart to ChartMuseum..."
    helm cm-push $chart internal
done

# Verify charts are available
helm search repo internal
```

### Step 6: Create a Chart Mirroring Script

Create a script to keep charts updated:

```bash
cat > /tmp/mirror-charts.sh <<'EOF'
#!/bin/bash
set -e

CHARTMUSEUM_URL="${CHARTMUSEUM_URL:-http://chartmuseum.chartmuseum.svc.cluster.local}"
TEMP_DIR="/tmp/chart-mirror-$(date +%s)"
mkdir -p ${TEMP_DIR}
cd ${TEMP_DIR}

# Function to mirror a chart
mirror_chart() {
    local repo_name=$1
    local repo_url=$2
    local chart_name=$3
    
    echo "Mirroring ${repo_name}/${chart_name}..."
    
    # Add repo if not exists
    helm repo add ${repo_name} ${repo_url} 2>/dev/null || true
    helm repo update
    
    # Pull chart
    helm pull ${repo_name}/${chart_name}
    
    # Push to ChartMuseum
    helm cm-push ${chart_name}*.tgz internal || {
        echo "Warning: Failed to push ${chart_name}"
    }
}

# Add internal repo
helm repo add internal ${CHARTMUSEUM_URL} || true
helm repo update

# Mirror all charts
mirror_chart "percona" "https://percona.github.io/percona-helm-charts/" "pxc-operator"
mirror_chart "percona" "https://percona.github.io/percona-helm-charts/" "pxc-db"
mirror_chart "minio" "https://charts.min.io/" "minio"
mirror_chart "litmuschaos" "https://litmuschaos.github.io/litmus-helm/" "litmus"

# Cleanup
cd -
rm -rf ${TEMP_DIR}

echo "Chart mirroring complete!"
EOF

chmod +x /tmp/mirror-charts.sh
```

### Step 7: Expose ChartMuseum via Ingress (Optional but Recommended)

For better integration, expose ChartMuseum via Ingress:

```bash
# Install ingress controller if not already installed
# For AWS, you can use AWS Load Balancer Controller

cat > /tmp/chartmuseum-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chartmuseum
  namespace: ${NAMESPACE}
  annotations:
    alb.ingress.kubernetes.io/scheme: internal  # or internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  ingressClassName: alb
  rules:
  - host: chartmuseum.your-domain.com  # Replace with your domain
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: chartmuseum
            port:
              number: 8080
EOF

kubectl apply -f /tmp/chartmuseum-ingress.yaml
```

## Configuration Changes Needed

To use your internal ChartMuseum repository, you would need to update these locations:

### 1. `src/percona.ts`

**Line 10**: Change default Helm repo URL:
```typescript
helmRepo: z.string().default('http://chartmuseum.chartmuseum.svc.cluster.local'),  // or your Ingress URL
```

**Line 440**: The `addRepos()` function will use the new URL automatically

**Line 644, 650**: MinIO repo addition - change to use internal repo or add MinIO charts to ChartMuseum

**Line 1724**: LitmusChaos repo addition - change to use internal repo or add LitmusChaos charts to ChartMuseum

### 2. `install-litmus.sh`

**Line 67**: Change LitmusChaos repo URL to your internal ChartMuseum

### 3. Test Files

Update any test files that reference external repos (e.g., `tests/unit/test_helm_repo_available.py`)

## Alternative: Using Nexus Repository Manager

If you prefer Nexus, here's a brief setup:

### Nexus Setup (More Complex)

```bash
# Add Nexus Helm repo
helm repo add sonatype https://sonatype.github.io/helm3-charts/
helm repo update

# Install Nexus
helm install nexus sonatype/nexus-repository-manager \
    --namespace nexus \
    --create-namespace \
    --set nexus.service.type=LoadBalancer

# Access Nexus UI (get password from secret)
kubectl get secret nexus-nexus-repository-manager-admin-password -n nexus -o jsonpath='{.data.password}' | base64 -d

# Create Helm (hosted) repository in Nexus UI or via API
# Then configure it similar to ChartMuseum
```

**Pros of Nexus:**
- Supports multiple artifact types (not just Helm)
- More enterprise features
- Better UI

**Cons of Nexus:**
- Heavier resource requirements
- More complex setup
- More configuration needed

## Security Considerations

1. **Authentication**: Consider adding authentication to ChartMuseum
   ```bash
   # Enable basic auth
   helm upgrade chartmuseum chartmuseum/chartmuseum \
       --namespace ${NAMESPACE} \
       --set env.open.BASIC_AUTH_USER=admin \
       --set env.open.BASIC_AUTH_PASS=<password>
   ```

2. **Network Policies**: Restrict access to ChartMuseum namespace

3. **TLS/HTTPS**: Use Ingress with TLS certificates for production

4. **IAM Permissions**: Follow least privilege for S3 access

## Automation: Keep Charts Updated

Set up a CronJob to periodically sync charts:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: chart-sync
  namespace: chartmuseum
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: helm
            image: alpine/helm:latest
            command:
            - /bin/sh
            - -c
            - |
              # Add repos and sync logic here
              helm repo add internal http://chartmuseum.chartmuseum.svc.cluster.local
              # ... mirror logic ...
          restartPolicy: OnFailure
```

## Testing Your Setup

```bash
# Test ChartMuseum is accessible
curl http://chartmuseum.chartmuseum.svc.cluster.local/api/charts

# Test Helm can access it
helm repo add internal http://chartmuseum.chartmuseum.svc.cluster.local
helm repo update
helm search repo internal

# Test installing a chart
helm install test-percona internal/pxc-operator --dry-run
```

## Troubleshooting

1. **Charts not found**: Verify ChartMuseum URL and that charts were pushed
2. **S3 access denied**: Check IAM role and service account annotations
3. **Network issues**: Verify service is accessible from your pods
4. **Chart version conflicts**: Ensure you're using the same chart versions

## Next Steps

1. Set up ChartMuseum following Step 1-4
2. Mirror your charts (Step 5)
3. Test with a small deployment
4. Update your code to use internal repo URLs
5. Set up automation for chart updates
6. Remove external repo access from your cluster (network policies)

## References

- [ChartMuseum Documentation](https://chartmuseum.com/docs/)
- [ChartMuseum Helm Chart](https://github.com/chartmuseum/charts)
- [AWS IAM Roles for Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Helm Push Plugin](https://github.com/chartmuseum/helm-push)


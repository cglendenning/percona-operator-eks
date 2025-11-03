# Quick Start: ChartMuseum Setup

This is a quick reference guide for setting up ChartMuseum. For detailed information, see `HELM_REPO_SETUP.md`.

## What is ChartMuseum?

ChartMuseum is an open-source Helm Chart Repository server that can store your Helm charts in S3. It's lightweight, Kubernetes-native, and perfect for EKS.

## Current External Repositories

Your code uses these external repos that we'll mirror:
- Percona: `https://percona.github.io/percona-helm-charts/`
- MinIO: `https://charts.min.io/`
- LitmusChaos: `https://litmuschaos.github.io/litmus-helm/`

## Quick Setup (3 Steps)

### Step 1: Install ChartMuseum

```bash
# Set your cluster name (if different from default)
export CLUSTER_NAME="percona-eks"
export AWS_REGION="us-east-1"

# Run the setup script
./setup-chartmuseum.sh
```

This script will:
- ✅ Create an S3 bucket for chart storage
- ✅ Set up IAM roles for S3 access (IRSA)
- ✅ Install ChartMuseum in your EKS cluster
- ✅ Configure it with S3 backend

**Expected output:** ChartMuseum URL (e.g., `http://chartmuseum.chartmuseum.svc.cluster.local`)

### Step 2: Mirror External Charts

```bash
# Set the ChartMuseum URL (from Step 1)
export CHARTMUSEUM_URL="http://chartmuseum.chartmuseum.svc.cluster.local"

# Mirror all charts
./mirror-charts.sh
```

This will download and upload:
- Percona charts (pxc-operator, pxc-db)
- MinIO chart
- LitmusChaos chart

### Step 3: Update Your Code (When Ready)

To use your internal repo, update these files:

**`src/percona.ts` (line 10):**
```typescript
helmRepo: z.string().default('http://chartmuseum.chartmuseum.svc.cluster.local'),
```

**`src/percona.ts` (lines 644, 650, 1724):**
- Either remove external repo additions, or
- Change to use internal repo after adding charts to ChartMuseum

**`install-litmus.sh` (line 67):**
- Change to use internal repo

## Testing Your Setup

```bash
# Add your internal repo
helm repo add internal http://chartmuseum.chartmuseum.svc.cluster.local
helm repo update

# Search for charts
helm search repo internal

# Test installing a chart (dry-run)
helm install test-percona internal/pxc-operator --dry-run --namespace percona
```

## Configuration Options

You can customize the setup with environment variables:

```bash
# Custom bucket name
export CHART_BUCKET_NAME="my-custom-chart-bucket"

# Custom namespace
export NAMESPACE="helm-repo"

# Service type (LoadBalancer, ClusterIP, NodePort)
export SERVICE_TYPE="LoadBalancer"

# Then run setup
./setup-chartmuseum.sh
```

## Troubleshooting

### ChartMuseum not accessible
```bash
# Check if pod is running
kubectl get pods -n chartmuseum

# Check service
kubectl get svc -n chartmuseum

# Check logs
kubectl logs -n chartmuseum -l app.kubernetes.io/name=chartmuseum
```

### S3 access issues
```bash
# Verify service account annotation
kubectl get sa chartmuseum -n chartmuseum -o yaml

# Check IAM role
kubectl describe sa chartmuseum -n chartmuseum
```

### Charts not found after mirroring
```bash
# Verify charts in S3
aws s3 ls s3://<your-bucket-name>/

# Check ChartMuseum API
curl http://chartmuseum.chartmuseum.svc.cluster.local/api/charts
```

## Next Steps

1. ✅ Run `./setup-chartmuseum.sh` to install ChartMuseum
2. ✅ Run `./mirror-charts.sh` to mirror external charts
3. ✅ Test with `helm search repo internal`
4. ⏳ Update code to use internal repo URLs
5. ⏳ Set up automation to keep charts updated (CronJob)
6. ⏳ Consider adding authentication/TLS for production

## Files Created

- `HELM_REPO_SETUP.md` - Detailed guide with all options
- `setup-chartmuseum.sh` - Installation script
- `mirror-charts.sh` - Chart mirroring script
- `QUICK_START_CHARTMUSEUM.md` - This file

## Uninstall

To remove ChartMuseum:

```bash
# Uninstall Helm release
helm uninstall chartmuseum -n chartmuseum

# Delete namespace
kubectl delete namespace chartmuseum

# Delete S3 bucket (careful - this deletes all charts!)
aws s3 rm s3://<your-bucket-name> --recursive
aws s3 rb s3://<your-bucket-name>

# Delete IAM resources (optional)
aws iam detach-role-policy --role-name ChartMuseumRole-<cluster-name> --policy-arn <policy-arn>
aws iam delete-role --role-name ChartMuseumRole-<cluster-name>
aws iam delete-policy --policy-arn <policy-arn>
```

## Need Help?

See the detailed guide: `HELM_REPO_SETUP.md`


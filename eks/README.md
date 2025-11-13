# EKS Cluster Deployment

This directory contains everything needed to deploy and manage an AWS EKS cluster for Percona XtraDB Cluster.

## Contents

- `cloudformation/` - CloudFormation templates for EKS infrastructure
- `scripts/` - Deployment and management scripts

## Prerequisites

- Node.js 18+
- Binaries on PATH:
  - awscli (`aws --version`)
  - kubectl (`kubectl version --client`)
  - helm (`helm version`)

## AWS Authentication

Choose one of the following:

### Option 1: AWS SSO (Recommended)

Check if you already have SSO configured:
```bash
cat ~/.aws/config
```

If you see an existing profile with `sso_session` configured, use it:
```bash
aws sso login --profile <profile-name>
export AWS_PROFILE=<profile-name>
```

Otherwise, set up a new SSO profile (requires SSO start URL from your AWS admin):
```bash
aws configure sso
aws sso login --profile <profile>
export AWS_PROFILE=<profile>
```

### Option 2: Access keys
```bash
aws configure
export AWS_PROFILE=default
```

### Option 3: Environment variables
```bash
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
export AWS_SESSION_TOKEN=<token>  # optional
```

Confirm authentication: `aws sts get-caller-identity`

## Deploy EKS Cluster

Deploy EKS cluster with 3 node groups (one per AZ):
```bash
./eks/scripts/deploy.sh
```

Or with verbose output:
```bash
./eks/scripts/deploy.sh -vv
```

The deployment script:
- Creates VPC with 3 public + 3 private subnets across us-east-1a, us-east-1c, us-east-1d
- Deploys 3 EKS managed node groups (1 per AZ) with m6i.xlarge On-Demand instances (optimized for multi-cluster environments)
- Installs EBS CSI driver, VPC CNI, CoreDNS, kube-proxy, and metrics-server add-ons
- Updates kubeconfig automatically
- Verifies multi-AZ node distribution

## Tear Down EKS Cluster

When not in use, tear down the cluster to avoid charges:
```bash
./eks/scripts/cleanup.sh
```

This script is **idempotent** and can be run multiple times. It will:
1. Delete the CloudFormation stack (if it exists)
2. Scan for and optionally delete orphaned resources:
   - **NAT Gateways** (~$32/month each, 3 created = **$97/month**!)
   - **Elastic IPs** (~$3.60/month each when unattached)
   - **EBS volumes** ($0.08/GB/month)
   - **Load Balancers** (~$16-23/month each)
   - **Network Interfaces**
   - **Security Groups**

The script asks for confirmation before deleting each resource type and shows cost estimates.

### Volumes-Only Cleanup

If you just want to clean up orphaned EBS volumes:

```bash
./eks/scripts/cleanup-volumes.sh
```

**Why this matters**: EBS volumes persist after cluster deletion and can cost $40-400/month if left behind!

### Why Orphaned Resources Happen & Their Costs

**Your $13.30 NAT Gateway charge came from 3 NAT Gateways left running at $0.045/hour each.**

When CloudFormation deletion fails or Kubernetes resources aren't cleaned up properly, these expensive resources can persist:

| Resource | Quantity | Cost Each | Monthly Total |
|----------|----------|-----------|---------------|
| **NAT Gateways** | 3 | $0.045/hr (~$32/mo) | **$97/month** |
| **Elastic IPs** (unattached) | 3 | $3.60/month | **$11/month** |
| **EBS Volumes** (50GB each) | 10-50 | $4/month | **$40-200/month** |
| **Load Balancers** | 1-3 | $16-23/month | **$16-69/month** |
| **Total Orphaned Cost** | | | **$164-377/month** |

**That's $1,968-$4,524 per year for resources doing nothing!**

## Cost Savings

**Recommended workflow:**
1. Deploy cluster: `./eks/scripts/deploy.sh`
2. Run tests/experiments
3. Tear down: `./eks/scripts/cleanup.sh`
4. Repeat as needed

**Costs when running:**
- ~$0.58/hour for 3 m6i.xlarge On-Demand instances (~$420/month) - **15% faster than m5.xlarge at similar cost**
- ~$0.10/hour for EKS control plane (~$73/month)
- ~$0.10/hour for EBS gp3 volumes (PXC + ProxySQL) (~$73/month)
- **Total: ~$0.43/hour or ~$10/day or ~$308/month** (if running 24/7)

**Costs when stopped:**
- $0 (all resources deleted)

### Instance Type Options

The default instance type is **m6i.xlarge** (optimized for multi-cluster environments):

| Instance Type | vCPUs | RAM | Price/Hour | Monthly (3 nodes) | Max Clusters | Use Case |
|---------------|-------|-----|------------|-------------------|--------------|----------|
| t3a.large | 2 | 8 GB | $0.0752 | ~$162 | 1 | Budget single-cluster |
| t3a.xlarge | 4 | 16 GB | $0.1504 | ~$324 | 2 | Budget multi-cluster |
| m5.large | 2 | 8 GB | $0.096 | ~$207 | 1 | Single-cluster stable |
| m5.xlarge | 4 | 16 GB | $0.192 | ~$414 | 2 | Multi-cluster (older gen) |
| **m6i.xlarge** (default) | 4 | 16 GB | $0.192 | ~$420 | 2 | ✅ Multi-cluster (15% faster) |
| m6i.2xlarge | 8 | 32 GB | $0.384 | ~$840 | 5 | Heavy multi-cluster |
| t3a.2xlarge | 8 | 32 GB | $0.3008 | ~$648 | 5 | Budget heavy multi-cluster |

**Why m6i.xlarge?**
- ✅ **48 GB total RAM** - run 2 full PXC clusters simultaneously
- ✅ **12 vCPU total** - sufficient for multiple workloads
- ✅ **15% faster** than m5.xlarge (3rd gen Intel Xeon Ice Lake)
- ✅ **12.5 Gbps network** - better for replication and backups
- ✅ Non-burstable - consistent, predictable performance
- ✅ Great for CI/CD with ephemeral test clusters
- ✅ Supports rapid cluster teardown/standup workflows

**To change instance type:**
```bash
# Edit eks/scripts/deploy.sh
NODE_INSTANCE_TYPE="m6i.xlarge"  # Change to your preferred type
```

Or pass as CloudFormation parameter:
```bash
aws cloudformation update-stack \
  --stack-name percona-eks-cluster \
  --use-previous-template \
  --parameters ParameterKey=NodeInstanceType,ParameterValue=m6i.2xlarge \
  --capabilities CAPABILITY_IAM
```


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
- Deploys 3 EKS managed node groups (1 per AZ) with m5.large On-Demand instances
- Installs EBS CSI driver, VPC CNI, CoreDNS, kube-proxy, and metrics-server add-ons
- Updates kubeconfig automatically
- Verifies multi-AZ node distribution

## Tear Down EKS Cluster

When not in use, tear down the cluster to avoid charges:
```bash
./eks/scripts/cleanup.sh
```

This deletes the CloudFormation stack and all associated resources.

## Cost Savings

**Recommended workflow:**
1. Deploy cluster: `./eks/scripts/deploy.sh`
2. Run tests/experiments
3. Tear down: `./eks/scripts/cleanup.sh`
4. Repeat as needed

**Costs when running:**
- ~$0.73/hour for 3 m5.large On-Demand instances
- ~$0.10/hour for EKS control plane
- ~$0.10/hour for EBS gp3 volumes (PXC + ProxySQL)
- **Total: ~$0.93/hour or ~$22/day**

**Costs when stopped:**
- $0 (all resources deleted)


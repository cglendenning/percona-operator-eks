## Percona EKS Automation

Automated deployment of EKS cluster with Percona XtraDB Cluster operator via CloudFormation and TypeScript.

### Prerequisites
- Node.js 18+
- Binaries on PATH:
  - awscli (`aws --version`)
  - kubectl (`kubectl version --client`)
  - helm (`helm version`)

### AWS authentication options
Choose one of the following:
- AWS SSO: `aws configure sso` then `aws sso login --profile <profile>`
- Access keys: `aws configure` and set AWS Access Key ID/Secret Access Key
- Env vars: export `AWS_PROFILE` or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (and optional `AWS_SESSION_TOKEN`)

Confirm: `aws sts get-caller-identity`

### Install dependencies
```bash
npm install
```

### EKS cluster deployment
Deploy EKS cluster with 3 node groups (one per AZ):
```bash
./deploy.sh
```

Or with verbose output:
```bash
./deploy.sh -vv
```

Delete cluster:
```bash
aws cloudformation delete-stack --stack-name percona-eks-cluster --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name percona-eks-cluster --region us-east-1
```

The deployment script:
- Creates VPC with 3 public + 3 private subnets across us-east-1a, us-east-1c, us-east-1d
- Deploys 3 EKS managed node groups (1 per AZ) with m5.large On-Demand instances
- Installs EBS CSI driver, VPC CNI, CoreDNS, kube-proxy, and metrics-server add-ons
- Updates kubeconfig automatically
- Verifies multi-AZ node distribution

### Percona operator and cluster
Install operator and 3-node cluster in namespace `percona`:
```bash
npm run percona -- install --namespace percona --name pxc-cluster --nodes 3
```

Uninstall and cleanup PVCs:
```bash
npm run percona -- uninstall --namespace percona --name pxc-cluster
```

### AWS Console Access
Grant your IAM user/role access to view Kubernetes resources in the AWS Console:
```bash
./grant-console-access.sh
```

This script:
- Auto-detects your SSO role and node group role ARNs
- Updates the aws-auth ConfigMap
- Creates EKS access entries for API-based authentication
- Associates cluster admin policy

After running, refresh the AWS Console to view nodes, pods, and services.

### Notes
- EKS control plane incurs ~$0.10/hr while the cluster exists; delete when done.
- Check for orphaned LoadBalancers and EBS volumes after uninstall/delete.
- CloudFormation template uses On-Demand instances by default (set `UseSpotInstances=true` for Spot, not recommended for databases).



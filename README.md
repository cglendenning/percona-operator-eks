## Percona EKS Automation (TypeScript)

Two TypeScript scripts to create/destroy an EKS cluster and install/uninstall the Percona XtraDB Cluster (3 nodes) via the Percona Operator.

### Prerequisites
- Node.js 18+
- Binaries on PATH:
  - awscli (`aws --version`)
  - eksctl (`eksctl version`)
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

### EKS lifecycle
Create:
```bash
npm run eks -- create --name percona-eks --region us-east-1 --version 1.29 --nodeType m6i.large --nodes 3 --spot true
```

Delete:
```bash
npm run eks -- delete --name percona-eks --region us-east-1
```

After create, kubeconfig is updated automatically.

### Percona operator and cluster
Install operator and 3-node cluster in namespace `percona`:
```bash
npm run percona -- install --namespace percona --name pxc-cluster --nodes 3
```

Uninstall and cleanup PVCs:
```bash
npm run percona -- uninstall --namespace percona --name pxc-cluster
```

### Notes
- EKS control plane incurs ~$0.10/hr while the cluster exists; delete when done.
- Check for orphaned LoadBalancers and EBS volumes after uninstall/delete.
- Default settings use Spot instances; disable with `--spot false`.



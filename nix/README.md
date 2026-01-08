# Nix Experiments - k3d and Istio

Modular Nix flake setup for managing a local k3d Kubernetes cluster with Istio service mesh.

## Structure

```
nix/
├── flake.nix              # Main flake - k3d cluster + Istio
├── fleet.nix              # Fleet configuration generator
├── modules/
│   ├── k3d/               # k3d cluster management
│   │   ├── flake.nix
│   │   └── default.nix
│   ├── helm/              # Helm chart rendering
│   │   ├── flake.nix
│   │   └── default.nix
│   └── istio/             # Istio configuration
│       ├── flake.nix
│       └── default.nix
└── README.md
```

## Quick Start

### 1. Show Available Outputs

```bash
cd nix
nix flake show
```

Shows all available packages, apps, and dev shells.

### 2. Check Flake Health

```bash
nix flake check
```

Validates the flake and all module dependencies.

### 3. Build Manifests

Build all manifests (k3d config + Istio):

```bash
nix build
```

This creates a `result` symlink with:
- `k3d-config.yaml` - k3d cluster configuration
- `manifest.yaml` - Complete Istio manifests (base + istiod + gateway)
- `bin/k3d-{create,delete,status}` - Cluster management scripts

Build individual components:

```bash
# Just k3d config
nix build .#k3d-config

# Just Istio base (CRDs)
nix build .#istio-base

# Just Istiod (control plane)
nix build .#istio-istiod

# Just Istio gateway
nix build .#istio-gateway

# All Istio components combined
nix build .#istio-all
```

### 4. Create and Configure Cluster

Enter development shell with all tools:

```bash
nix develop
```

Or use apps directly:

```bash
# Create cluster
nix run .#create-cluster

# Check status
nix run .#status

# Delete cluster
nix run .#delete-cluster
```

Manual cluster management:

```bash
# Create cluster
./result/bin/k3d-create

# Deploy Istio
kubectl apply -f result/manifest.yaml

# Verify deployment
kubectl get pods -n istio-system
kubectl get svc -n istio-system

# Check Istio version
istioctl version

# Delete cluster when done
./result/bin/k3d-delete
```

## Fleet Deployment

Fleet provides GitOps-style deployment with dependency management.

### Build Fleet Configuration

```bash
# First build the main manifests
nix build

# Then build Fleet configuration
nix build -f fleet.nix
```

This generates:
- `fleet.yaml` - Fleet bundle definitions
- `deploy-fleet.sh` - Automated Fleet deployment script
- `check-status.sh` - Status checking script

### Deploy Istio via Fleet

```bash
# Automated deployment (installs Fleet if needed)
./result/deploy-fleet.sh

# Or manual deployment
kubectl create namespace fleet-system
helm repo add fleet https://rancher.github.io/fleet-helm-charts/
helm install fleet fleet/fleet -n fleet-system --wait

kubectl apply -f result/fleet.yaml

# Check deployment status
./result/check-status.sh

# Or check manually
kubectl get bundles -n fleet-local
kubectl get pods -n istio-system -w
```

### Fleet Bundle Order

Fleet automatically handles deployment order via dependencies:

1. `istio-base` - CRDs and cluster roles
2. `istio-istiod` - Control plane (depends on istio-base)
3. `istio-gateway` - Ingress gateway (depends on istio-istiod)

## Adding New Helm Charts

The modular structure makes it easy to add new charts.

See `examples/README.md` for detailed examples including cert-manager and Prometheus.

### Option 1: Use Helm Module Directly

Edit `flake.nix` and add a new package:

```nix
my-app = helmLib.mkHelmChart {
  name = "my-app";
  chart = "my-app";
  repo = "https://charts.example.com";
  version = "1.0.0";
  namespace = "my-namespace";
  values = {
    replicas = 3;
    image.tag = "latest";
  };
};
```

Then build: `nix build .#my-app`

### Option 2: Create a New Module

For complex applications, create a dedicated module:

```bash
mkdir -p modules/my-app
```

Create `modules/my-app/flake.nix`:

```nix
{
  description = "My application module";
  outputs = { self, ... }: {
    lib = { pkgs }: import ./default.nix { inherit pkgs; };
  };
}
```

Create `modules/my-app/default.nix`:

```nix
{ pkgs }:

let
  helmLib = import ../helm/default.nix { inherit pkgs; };
in
{
  defaultValues = {
    # Your default values
  };

  mkMyApp = { namespace ? "default", values ? {} }:
    helmLib.mkHelmChart {
      name = "my-app";
      chart = "my-app";
      repo = "https://charts.example.com";
      inherit namespace values;
    };
}
```

Add to main `flake.nix` inputs:

```nix
inputs = {
  # ... existing inputs
  my-app.url = "path:./modules/my-app";
};

outputs = { self, nixpkgs, k3d, helm, istio, my-app }:
  # ... use my-app.lib in packages
```

See `examples/` directory for working examples.

## Module System

Each module is a self-contained flake that exports a `lib` function.

### k3d Module

Functions:
- `mkClusterConfig` - Generate k3d cluster configuration
- `mkClusterScript` - Generate cluster management scripts

### helm Module

Functions:
- `mkHelmChart` - Render any Helm chart to manifests

Parameters:
- `name` - Release name
- `chart` - Chart name or path
- `repo` - Helm repository URL (optional)
- `version` - Chart version (optional)
- `namespace` - Target namespace
- `values` - Values to override
- `createNamespace` - Create namespace if missing

### istio Module

Functions:
- `mkIstioBase` - Render Istio base chart (CRDs)
- `mkIstiod` - Render Istiod control plane
- `mkIstioGateway` - Render Istio ingress gateway

Exports:
- `defaultValues` - Opinionated Istio configurations

## Customization

### Change Cluster Configuration

Edit the `k3d-config` package in `flake.nix`:

```nix
k3d-config = k3dLib.mkClusterConfig {
  name = "my-cluster";
  servers = 3;        # High availability
  agents = 5;         # More worker nodes
  ports = [
    { host = "8080"; container = "80"; nodeFilters = [ "loadbalancer" ]; }
  ];
  options = {
    k3s-server-arg = [
      "--disable=traefik"
      "--disable=metrics-server"
    ];
  };
};
```

### Change Istio Configuration

Edit the Istio packages in `flake.nix`:

```nix
istio-istiod = istioLib.mkIstiod {
  namespace = istioNamespace;
  values = istioLib.defaultValues.istiod // {
    pilot.resources.requests = {
      cpu = "500m";
      memory = "2Gi";
    };
    meshConfig = {
      accessLogFile = "/dev/stdout";
      enableTracing = true;
    };
  };
};
```

Or modify `modules/istio/default.nix` to change defaults for all deployments.

## Development Workflow

### Typical Session

```bash
# Enter dev shell
nix develop

# Create cluster
k3d-create

# Deploy Istio
kubectl apply -f result/manifest.yaml

# Work with cluster
kubectl get all -A
istioctl proxy-status

# Make changes to flake.nix
# Rebuild
nix build

# Apply changes
kubectl apply -f result/manifest.yaml

# Cleanup
k3d-delete
```

### Testing Changes

```bash
# Check flake syntax
nix flake check

# Build without creating symlink
nix build --no-link

# Show build logs
nix build --print-build-logs

# Evaluate expression
nix eval .#packages.aarch64-darwin.istio-all
```

## Troubleshooting

### Cluster Creation Fails

```bash
# Check existing clusters
k3d cluster list

# Delete conflicting cluster
k3d cluster delete local

# Check port availability
lsof -i :80
lsof -i :443
```

### Istio Pods Not Starting

```bash
# Check pod status
kubectl get pods -n istio-system

# View pod logs
kubectl logs -n istio-system deployment/istiod

# Check events
kubectl get events -n istio-system --sort-by='.lastTimestamp'

# Validate configuration
istioctl analyze
```

### Fleet Bundles Not Deploying

```bash
# Check Fleet controller
kubectl get pods -n fleet-system

# View bundle status
kubectl get bundles -n fleet-local -o yaml

# Check bundle resources
kubectl describe bundle istio-base -n fleet-local
```

### Rebuild Everything

```bash
# Delete cluster
k3d cluster delete local

# Clean Nix build artifacts
nix store gc

# Rebuild
nix build

# Start fresh
nix run .#create-cluster
kubectl apply -f result/manifest.yaml
```

## Reference

### Nix Commands

- `nix flake show` - Show all flake outputs
- `nix flake check` - Validate flake
- `nix flake update` - Update flake inputs
- `nix flake lock` - Generate/update lock file
- `nix build` - Build default package
- `nix build .#<package>` - Build specific package
- `nix develop` - Enter development shell
- `nix run .#<app>` - Run application

### kubectl Commands

- `kubectl cluster-info` - Show cluster information
- `kubectl get all -A` - List all resources
- `kubectl get pods -n istio-system` - Istio pods
- `kubectl logs -n istio-system <pod>` - View logs
- `kubectl describe pod -n istio-system <pod>` - Pod details

### istioctl Commands

- `istioctl version` - Show versions
- `istioctl proxy-status` - Proxy sync status
- `istioctl analyze` - Analyze configuration
- `istioctl dashboard kiali` - Open Kiali dashboard

### k3d Commands

- `k3d cluster list` - List clusters
- `k3d cluster create` - Create cluster
- `k3d cluster delete` - Delete cluster
- `k3d kubeconfig get` - Get kubeconfig

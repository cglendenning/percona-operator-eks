# Nix k3d + Istio

Modular Nix flake for k3d clusters with Istio service mesh.

## Structure

```
nix/
├── flake.nix           # Main orchestrator
└── modules/            # Modular components
    ├── k3d/           # k3d cluster config
    ├── helm/          # Helm chart renderer
    ├── istio/         # Istio components
    └── service-entry/ # Cross-cluster service discovery
```

## Usage

### Basic Setup

```bash
# Show available outputs
nix flake show

# Build everything
nix build

# Create cluster
./result/bin/k3d-create

# Deploy Istio
./result/deploy.sh

# Verify
kubectl get pods -n istio-system

# Cleanup
./result/bin/k3d-delete
```

### Build Specific Components

```bash
nix build .#k3d-config        # Just k3d config
nix build .#istio-base        # Just Istio CRDs
nix build .#istio-istiod      # Just control plane
```

## Adding Helm Charts

Use the helm module:

```nix
# In flake.nix packages
my-chart = helmLib.mkHelmChart {
  name = "my-app";
  chart = "my-app";
  repo = "https://charts.example.com";
  namespace = "default";
  values = { replicas = 3; };
};
```

See `examples/` for more.

## PXC Cross-Cluster Replication

Use ServiceEntry to reference remote clusters by DNS instead of IPs:

```nix
# In flake.nix packages
pxc-remote = serviceEntryLib.mkPXCServiceEntry {
  name = "pxc-source";
  namespace = "pxc";
  remoteClusterName = "cluster-b";
  remoteEndpoints = [
    { address = "172.19.0.2"; port = 3306; }
  ];
};
```

Build and apply:

```bash
nix build .#pxc-remote
kubectl apply -f result/manifest.yaml
```

Then in PXC:

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='pxc-source.cluster-b.global',
  SOURCE_PORT=3306;
```

No need for `pxc.expose = true` or external IPs.

## Module System

Each module exports functions via `lib`:

- **k3d**: `mkClusterConfig`, `mkClusterScript`
- **helm**: `mkHelmChart` (renders any Helm chart)
- **istio**: `mkNamespace`, `mkIstioBase`, `mkIstiod`, `mkIstioGateway`
- **service-entry**: `mkServiceEntry`, `mkPXCServiceEntry`

Modules use Helm chart defaults. Only override what's necessary.

## Customization

Edit `flake.nix`:

```nix
istio-istiod = istioLib.mkIstiod {
  namespace = "istio-system";
  values = {
    pilot.resources.requests = {
      cpu = "500m";
      memory = "2Gi";
    };
  };
};
```

Rebuild: `nix build`

## How It Works

1. Nix evaluates `flake.nix`
2. Modules render Helm charts to YAML at build time
3. Output written to `/nix/store/`
4. `result` symlinks to output
5. Apply with `kubectl apply -f result/manifest.yaml`

Pure, reproducible, no runtime templating.

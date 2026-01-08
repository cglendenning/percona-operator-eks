# Examples - Adding New Helm Charts and Services

This directory contains examples showing how to add new Helm charts and Istio resources to your Nix flake.

## Available Examples

- `cert-manager.nix` - Certificate management
- `prometheus.nix` - Monitoring stack
- `pxc-serviceentry.nix` - Percona XtraDB cross-cluster replication

## Using Examples

### Option 1: Quick Addition (Direct in flake.nix)

For simple charts, add directly to your main `flake.nix`:

```nix
packages = forAllSystems (system:
  let
    pkgs = nixpkgs.legacyPackages.${system};
    helmLib = helm.lib { inherit pkgs; };
  in
  {
    # ... existing packages ...

    # Add cert-manager
    cert-manager = helmLib.mkHelmChart {
      name = "cert-manager";
      chart = "cert-manager";
      repo = "https://charts.jetstack.io";
      version = "v1.16.2";
      namespace = "cert-manager";
      values = {
        installCRDs = true;
      };
    };
  }
);
```

Then build: `nix build .#cert-manager`

### Option 2: Create a Module (Recommended for Complex Charts)

For charts with complex configurations, create a dedicated module.

#### 1. Create the module structure

```bash
mkdir -p modules/cert-manager
cp examples/cert-manager.nix modules/cert-manager/flake.nix
```

#### 2. Add to main flake.nix inputs

```nix
inputs = {
  # ... existing inputs ...
  cert-manager.url = "path:./modules/cert-manager";
};

outputs = { self, nixpkgs, k3d, helm, istio, cert-manager }:
```

#### 3. Use in packages

```nix
packages = forAllSystems (system:
  let
    pkgs = nixpkgs.legacyPackages.${system};
    certManagerLib = cert-manager.lib { inherit pkgs; };
  in
  {
    # ... existing packages ...

    cert-manager = certManagerLib.mkCertManager {
      namespace = "cert-manager";
      values = certManagerLib.defaultValues;
    };
  }
);
```

#### 4. Build and deploy

```bash
nix build .#cert-manager
kubectl apply -f result/manifest.yaml
```

## Example: Full Integration with Prometheus

Here's how to add the Prometheus stack alongside Istio:

### 1. Copy example to modules

```bash
mkdir -p modules/prometheus
cp examples/prometheus.nix modules/prometheus/flake.nix
```

### 2. Update main flake.nix

```nix
{
  description = "k3d cluster with Istio and Prometheus";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    k3d.url = "path:./modules/k3d";
    helm.url = "path:./modules/helm";
    istio.url = "path:./modules/istio";
    prometheus.url = "path:./modules/prometheus";
  };

  outputs = { self, nixpkgs, k3d, helm, istio, prometheus }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          prometheusLib = prometheus.lib { inherit pkgs; };
        in
        {
          # ... existing packages ...

          # Add Prometheus
          prometheus = prometheusLib.mkPrometheusStack {
            namespace = "monitoring";
            values = prometheusLib.defaultValues;
          };

          # Combined deployment with Istio and Prometheus
          all-services = pkgs.runCommand "all-services" { } ''
            mkdir -p $out
            
            echo "# Istio" > $out/manifest.yaml
            cat ${self.packages.${system}.istio-all}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Prometheus Stack" >> $out/manifest.yaml
            cat ${self.packages.${system}.prometheus}/manifest.yaml >> $out/manifest.yaml
          '';
        }
      );
    };
}
```

### 3. Build and deploy everything

```bash
nix build .#all-services
kubectl apply -f result/manifest.yaml
```

## Common Helm Repositories

### Bitnami
```nix
repo = "https://charts.bitnami.com/bitnami";
```

### Jetstack (cert-manager)
```nix
repo = "https://charts.jetstack.io";
```

### Prometheus Community
```nix
repo = "https://prometheus-community.github.io/helm-charts";
```

### Grafana
```nix
repo = "https://grafana.github.io/helm-charts";
```

### Elastic
```nix
repo = "https://helm.elastic.co";
```

### HashiCorp
```nix
repo = "https://helm.releases.hashicorp.com";
```

## Tips

### Finding Chart Versions

```bash
helm repo add <name> <url>
helm repo update
helm search repo <chart> --versions
```

### Extracting Default Values

```bash
helm show values <repo>/<chart> --version <version> > default-values.yaml
```

### Testing Rendered Manifests

```bash
nix build .#<package>
cat result/manifest.yaml | kubectl apply --dry-run=client -f -
```

### Viewing Rendered YAML

```bash
nix build .#<package>
bat result/manifest.yaml  # or cat, less, etc.
```

## Advanced: Multi-Chart Dependencies

Create a module that combines multiple charts with dependencies:

```nix
{ pkgs }:

let
  helmLib = import ../helm/default.nix { inherit pkgs; };
in
{
  # Create a complete observability stack
  mkObservabilityStack = {
    namespace ? "observability",
  }:
    let
      prometheus = helmLib.mkHelmChart {
        name = "prometheus";
        chart = "kube-prometheus-stack";
        repo = "https://prometheus-community.github.io/helm-charts";
        inherit namespace;
        createNamespace = true;
        values = { /* ... */ };
      };

      loki = helmLib.mkHelmChart {
        name = "loki";
        chart = "loki-stack";
        repo = "https://grafana.github.io/helm-charts";
        inherit namespace;
        values = { /* ... */ };
      };

      tempo = helmLib.mkHelmChart {
        name = "tempo";
        chart = "tempo";
        repo = "https://grafana.github.io/helm-charts";
        inherit namespace;
        values = { /* ... */ };
      };
    in
    pkgs.runCommand "observability-stack" { } ''
      mkdir -p $out
      cat ${prometheus}/manifest.yaml > $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${loki}/manifest.yaml >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${tempo}/manifest.yaml >> $out/manifest.yaml
    '';
}
```

This pattern allows you to create opinionated, pre-configured stacks that work together.

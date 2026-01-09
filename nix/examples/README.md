# Examples

## cert-manager.nix

Add cert-manager via Helm:

```nix
cert-manager = helmLib.mkHelmChart {
  name = "cert-manager";
  chart = "cert-manager";
  repo = "https://charts.jetstack.io";
  version = "v1.16.2";
  namespace = "cert-manager";
  values = { installCRDs = true; };
};
```

## prometheus.nix

Add Prometheus stack:

```nix
prometheus = helmLib.mkHelmChart {
  name = "kube-prometheus-stack";
  chart = "kube-prometheus-stack";
  repo = "https://prometheus-community.github.io/helm-charts";
  namespace = "monitoring";
  values = {
    prometheus.retention = "30d";
    grafana.enabled = true;
  };
};
```

## pxc-serviceentry.nix

ServiceEntry for remote PXC cluster:

```nix
pxc-remote = serviceEntryLib.mkPXCServiceEntry {
  name = "pxc-prod";
  namespace = "pxc";
  remoteClusterName = "production";
  remoteEndpoints = [
    { address = "10.0.1.10"; }
  ];
};
```

Then reference in PXC: `pxc-prod.production.global:3306`

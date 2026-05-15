# Local k3d profile: only the Grafana Seaweed alert provisioning ConfigMap bundle.
# Use `nix build .#grafana-seaweed-alert-manifests` (from nix/wookie-nixpkgs) to render.
[
  ../projects/grafana-seaweed
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "grafana-sw-alerts";
      apiPort = 6446;
    };

    projects.grafanaSeaweed = {
      enable = true;
      namespace = "monitoring";
      prometheusDatasourceUid = "prometheus";
      # dependsOn = [ "grafana" ];  # set to your Grafana Helm bundle name when using Fleet ordering
    };
  }
]

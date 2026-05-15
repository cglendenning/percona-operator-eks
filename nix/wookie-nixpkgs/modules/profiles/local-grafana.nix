# Local k3d profile: Grafana Helm release with Nix-provisioned SeaweedFS alerts.
[
  ../projects/grafana
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "grafana";
      apiPort = 6447;
    };

    projects.grafana = {
      enable = true;
      namespace = "monitoring";
      prometheusDatasourceUid = "prometheus";
    };
  }
]

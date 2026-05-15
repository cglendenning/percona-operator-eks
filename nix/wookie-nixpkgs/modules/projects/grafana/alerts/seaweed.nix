# SeaweedFS volume alerts (domain definitions only).
# Rendered via `lib/grafana-alerting.nix` into Helm `values.alerting."seaweed.yaml"`.
#
# Disk ratios match `pxc-pmm-alerts/pxc-pmm-alerts.nix` PXC Disk Usage rules:
# `(free / (free + used)) * 100 < threshold`, `noDataState = OK`.
{ }:
[
  {
    title = "SeaweedFS Volume Data1 Free Space Warning";
    expr = ''
      (
        SeaweedFS_volumeServer_resource{name="/data1",type="free"}
        /
        clamp_min(
          SeaweedFS_volumeServer_resource{name="/data1",type="free"}
          + ignoring(type) SeaweedFS_volumeServer_resource{name="/data1",type="used"},
          1
        )
      ) * 100 < 30'';
    for = "10m";
    noDataState = "OK";
    labels = {
      source = "wookie";
      severity = "warning";
    };
  }
  {
    title = "SeaweedFS Volume Data1 Free Space Critical";
    expr = ''
      (
        SeaweedFS_volumeServer_resource{name="/data1",type="free"}
        /
        clamp_min(
          SeaweedFS_volumeServer_resource{name="/data1",type="free"}
          + ignoring(type) SeaweedFS_volumeServer_resource{name="/data1",type="used"},
          1
        )
      ) * 100 < 20'';
    for = "5m";
    noDataState = "OK";
    labels = {
      source = "wookie";
      severity = "critical";
    };
  }
]

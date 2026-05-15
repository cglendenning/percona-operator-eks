# Grafana unified-alerting rules provisioned as static YAML (file provisioning).
# Same attribute shape as `../pmm/alerts.nix`:
#   - PMM template rules: `template_name`, `name`, `group`, `params`, `for`, `severity`,
#     `custom_labels`, `filters` (ignored here unless you also add `expr`)
#   - Custom PromQL rules: `name`, `group`, `expr`, `for`, optional `no_data_state`,
#     `custom_labels`
#
# This module only renders entries that include `expr`. Template-only rows are ignored
# with a trace warning at eval time.
#
# Disk-style ratios follow `pxc-pmm-alerts/pxc-pmm-alerts.nix` (PXC Disk Usage Warning /
# Critical): `(bytes_free / total_bytes) * 100 < threshold` with `no_data_state = "OK"`.
# Here total is `free + used` on the same volume (labels matched except `type`).
{ }:
[
  {
    name = "SeaweedFS Volume Data1 Free Space Warning";
    group = "seaweed-alerts";
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
    no_data_state = "OK";
    custom_labels = {
      source = "wookie";
      severity = "warning";
    };
  }
  {
    name = "SeaweedFS Volume Data1 Free Space Critical";
    group = "seaweed-alerts";
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
    no_data_state = "OK";
    custom_labels = {
      source = "wookie";
      severity = "critical";
    };
  }
]

# Grafana unified-alerting rules provisioned as static YAML (file provisioning).
# Same attribute shape as `../pmm/alerts.nix`:
#   - PMM template rules: `template_name`, `name`, `group`, `params`, `for`, `severity`,
#     `custom_labels`, `filters` (ignored here unless you also add `expr`)
#   - Custom PromQL rules: `name`, `group`, `expr`, `for`, optional `no_data_state`,
#     `custom_labels`
#
# This module only renders entries that include `expr`. Template-only rows are ignored
# with a trace warning at eval time.
{ }:
[
  {
    name = "SeaweedFS Volume Data1 Available Space Low";
    group = "seaweed-alerts";
    # `avail` is treated as bytes (Seaweed exporter convention). Tune threshold per environment.
    expr = ''SeaweedFS_volumeServer_resource{name="/data1",type="avail"} < 10737418240'';
    for = "5m";
    no_data_state = "OK";
    custom_labels = {
      source = "wookie";
      severity = "warning";
    };
  }
]

# PMM alert rules provisioned on startup via the /v1/alerting/rules API.
# Each entry maps directly to a CreateRule request body.
# Add more rules here; the provisioner Job picks them up on next helmfile sync.
{ }:
[
  {
    template_name = "pmm_mysql_down";
    name          = "MySQL Instance Down";
    group         = "wookie-pmm";
    params        = [];
    for           = "60s";
    severity      = "SEVERITY_CRITICAL";
    custom_labels = { source = "wookie"; };
    filters       = [];
  }
  {
    # Custom expr rule (no PMM template) - provisioned via Grafana ruler API.
    # absent() returns 1 when no mysql_global_status_uptime series exist (zero
    # MySQL instances reporting to PMM), and nothing when instances are present.
    # no_data_state=OK means: no data on the threshold check = MySQL is present = not alerting.
    name          = "No MySQL Instances Monitored";
    group         = "wookie-pmm";
    expr          = "absent(mysql_global_status_uptime)";
    for           = "120s";
    no_data_state = "OK";
    custom_labels = { source = "wookie"; severity = "critical"; };
  }
]

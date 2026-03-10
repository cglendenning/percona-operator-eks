# PMM alert rules provisioned on startup via the /v1/alerting/rules API.
# Each entry maps directly to a CreateRule request body.
# Add more rules here; the provisioner sidecar picks them up on next pod start.
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
]

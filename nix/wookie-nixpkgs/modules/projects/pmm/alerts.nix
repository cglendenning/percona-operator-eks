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
    # Fires when PMM is monitoring zero MySQL instances - indicates the
    # monitoring pipeline itself has lost visibility of all MySQL services.
    # Template name: verify against GET /v1/alerting/templates on your PMM instance.
    template_name = "pmm_mysql_not_enough_instances";
    name          = "No MySQL Instances Monitored";
    group         = "wookie-pmm";
    params        = [
      {
        name  = "threshold";
        type  = "PARAM_TYPE_FLOAT";
        float = { value = 1; };
      }
    ];
    for           = "120s";
    severity      = "SEVERITY_CRITICAL";
    custom_labels = { source = "wookie"; };
    filters       = [];
  }
]

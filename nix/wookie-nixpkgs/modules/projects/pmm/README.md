# PMM

## Alert provisioning

Alert rules are defined in `alerts.nix` as Nix attribute sets and provisioned automatically on pod startup via the `alert-provisioner` sidecar container.

The sidecar polls `GET /v1/readyz` until PMM is ready, then idempotently POSTs each rule to `POST /v1/alerting/rules`. If a rule with the same `name` already exists it is skipped.

### Adding alert rules

Add an entry to the list in `alerts.nix`. Each entry maps directly to a `CreateRule` request body:

```nix
{
  template_name = "pmm_mysql_down";
  name          = "MySQL Instance Down";
  group         = "wookie-pmm";
  params        = [];
  for           = "60s";           # protobuf Duration: seconds string
  severity      = "SEVERITY_CRITICAL";
  custom_labels = { source = "wookie"; };
  filters       = [];              # empty = fire on any matching instance
}
```

Available templates: `GET /v1/alerting/templates` via the PMM API or the `/swagger` UI.

### Verifying

```bash
# Watch provisioner output during startup
kubectl logs -n <namespace> <pod> -c alert-provisioner -f

# Confirm rules were created
curl -su admin:<password> http://localhost:<port>/v1/alerting/rules \
  | grep -o '"name":"[^"]*"'
```

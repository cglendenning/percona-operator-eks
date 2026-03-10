# PMM

Deploys PMM via the official Percona Helm chart and provisions alert rules
via a post-deploy Job.

## Configuration

```nix
projects.pmm = {
  enable        = true;
  namespace     = "pmm";
  adminPassword = "admin";
  chartVersion  = "3.0.0";
  chartHash     = "<sha256 - see below>";

  # Optional overrides
  storageClass = "standard";   # "gp3" on AWS, "standard" on k3d
  storageSize  = "20Gi";
  serviceName  = "pmm";        # Helm release name = service name
  resources    = {
    requests = { memory = "1Gi"; cpu = "500m"; };
    limits   = { memory = "2Gi"; cpu = "1"; };
  };
};
```

### Getting the chart hash

```bash
nix-prefetch-url https://percona.github.io/percona-helm-charts/pmm-3.0.0.tgz
```

The output is the `chartHash` value.

## Alert rules

Rules are declared in `alerts.nix` as Nix attribute sets. Each entry is a
`POST /v1/alerting/rules` request body:

```nix
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
```

Available templates: `GET /v1/alerting/templates` on the PMM instance.

When `alerts.nix` changes, a SHA-based annotation on the provisioner Job
changes, causing Helm to re-execute the hook on the next `helmfile sync`.
Existing rules are not duplicated (idempotent check before each POST).

## How it works

| Bundle | Type | Behaviour |
|--------|------|-----------|
| `pmm-server` | Helm chart | Deploys PMM via Percona chart |
| `pmm-alerts` | Raw manifests | ConfigMap + post-install/upgrade Job |

The `pmm-alerts` bundle `dependsOn` `pmm-server`. The Job polls
`/v1/readyz` until PMM is ready, then provisions any missing rules.
Helm deletes the previous Job before creating a new one
(`before-hook-creation`) and cleans up on success (`hook-succeeded`).

## Verifying

```bash
kubectl logs -n pmm -l app.kubernetes.io/name=pmm-alert-provisioner

curl -sku admin:<password> https://localhost:<port>/v1/alerting/rules \
  | grep -o '"name":"[^"]*"'
```

# Grafana SeaweedFS alerts (static provisioning)

Nix module that renders **Grafana unified alerting file provisioning** YAML into a Kubernetes `ConfigMap`, using the **same rule attribute shape** as `../pmm/alerts.nix`:

- **PMM template row** (ignored here unless you also set `expr`): `template_name`, `name`, `group`, `params`, `for`, `severity`, `custom_labels`, `filters`
- **PromQL row** (rendered): `name`, `group`, `expr`, `for`, optional `no_data_state`, `custom_labels`

Only rules that include **`expr`** are written into `seaweed-alert-rules.yaml`. Template-only entries emit a **trace** warning at eval time.

## Enable

```nix
{ imports = [ ./modules/projects/grafana-seaweed ]; }

projects.grafanaSeaweed = {
  enable = true;
  namespace = "monitoring";
  prometheusDatasourceUid = "prometheus"; # must match your Grafana Prometheus datasource UID
};
```

## Fleet / Helm mount

Mount the ConfigMap into Grafana (paths relative to `/etc/grafana`):

| ConfigMap key | Mount path |
|---------------|------------|
| `seaweed-alert-rules.yaml` | `provisioning/alerting/seaweed-alert-rules.yaml` |
| `seaweed-datasources.yaml` (optional) | `provisioning/datasources/seaweed-datasources.yaml` |

Set `projects.grafanaSeaweed.provisionPrometheusDatasource = true` only if Grafana should create the Prometheus datasource from this same ConfigMap. Otherwise keep the default `false` and align `prometheusDatasourceUid` with an existing datasource.

Use **`dependsOn`** on the bundle for ordering relative to your Grafana release name in `platform.kubernetes.cluster.batches.*.bundles`.

## Build manifests

From `nix/wookie-nixpkgs`:

```bash
nix build .#grafana-seaweed-alert-manifests
cat result/manifest.yaml
```

## Rules

Edit `alerts.nix` (same style as `../pmm/alerts.nix`). The default rule fires when `avail` bytes for `name="/data1"` fall below 10Gi for 5 minutes.

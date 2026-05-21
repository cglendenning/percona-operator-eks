# Grafana (Helm) with Nix-provisioned alerts

Deploys Grafana via the [official Grafana Helm chart](https://github.com/grafana/helm-charts/tree/main/charts/grafana) and injects unified-alerting rules through chart `values.alerting` (file provisioning inside the release).

## Layout

| Path | Role |
|------|------|
| `alerts/seaweed.nix` | Alert definitions (title, PromQL `expr`, `for`, labels) |
| `default.nix` | Helm bundle + `alerting."seaweed.yaml"` from `lib/grafana-alerting.nix` |
| `../../../lib/grafana-alerting.nix` | Maps boolean PromQL specs to Grafana rule `data` (A → B → C) |

## Enable

```nix
{ imports = [ ./modules/projects/grafana ]; }

projects.grafana = {
  enable = true;
  namespace = "monitoring";
  prometheusDatasourceUid = "prometheus";
};
```

## Build manifests

```bash
cd nix/wookie-nixpkgs
nix build .#grafana-manifests
```

## Local profile

```bash
nix build .#grafana-manifests   # from nix/wookie-nixpkgs flake
```

Profile: `modules/profiles/local-grafana.nix` (`grafanaConfig`).

## SeaweedFS disk alerts

Uses `(avail / all) * 100` with **`ignoring(type)`** because `type` differs on each side of the division. Warning below 30% for 10m, critical below 20% for 5m. Confirm the `name` label matches your volume dir (default `/data1`).

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

## Kubernetes monitoring (kube-state-metrics → PMM)

Percona’s [Monitor Kubernetes](https://docs.percona.com/percona-operator-for-mysql/pxc/monitor-kubernetes.html) flow: Victoria Metrics k8s stack + `customresource-config-ksm` (PXC backup CR metrics) remote-writing to PMM.

```nix
projects.pmm = {
  enable = true;
  # ... pmm-server options ...

  k8sMonitoring = {
    enable = true;
    # Default namespace: wookie-observability (same as pmm-service-account-token Secret).
    k8sClusterId = "my-k3d-cluster"; # unique per K8s cluster → PMM
    nodeExporterEnabled = false;   # true only if you need node-exporter
  };
};
```

| Bundle | Type | Contents |
|--------|------|----------|
| `pmm-k8s-monitoring-prereqs` | Manifests | ConfigMap `customresource-config-ksm` from `ksm-configmap.nix` (Percona k8s-monitoring v0.1.1) |
| `pmm-k8s-monitoring` | Helm | `vm/victoria-metrics-k8s-stack` @ `0.30.3` (Percona pin) |

`dependsOn` `pmm-server` so PMM exists before vmagent remote-write.

### Victoria Metrics Operator CRDs (Helm, WSL)

`helm template` does **not** include CRDs unless you pass `--include-crds`. Apply
CRDs **before** `VMAgent`, `VMServiceScrape`, or any other
`*.operator.victoriametrics.com` resource.

Chart pin: `victoria-metrics-k8s-stack` **0.30.3** → operator **0.39.0** (16 CRDs).

Run in WSL (bash). Set `KUBECONFIG` if your context is not the default:

```bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update vm

# Render CRDs only and apply (multi-doc YAML split on "---")
helm template vm-operator-crds vm/victoria-metrics-operator \
  --version 0.39.0 \
  --include-crds \
  | awk 'BEGIN{RS="---"; ORS="---\n"} /kind: CustomResourceDefinition/' \
  | kubectl --kubeconfig="$KUBECONFIG" apply -f -

# Wait until the API accepts VM CRs (required before the rest of the stack)
kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Established \
  crd/vmagents.operator.victoriametrics.com --timeout=120s
kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Established \
  crd/vmservicescrapes.operator.victoriametrics.com --timeout=120s

# Sanity check
kubectl --kubeconfig="$KUBECONFIG" get crd \
  | grep operator.victoriametrics.com
```

Then deploy the operator + vmagent + kube-state-metrics manifests (fleet, helm
install, etc.). Nix alternative: `vm-operator-crds.nix` → `mkCrdsManifest`.

### Verify metrics in PMM (after `helmfile sync`)

1. Port-forward PMM: `kubectl port-forward -n pmm svc/monitoring-service 8443:https`
2. Grafana → **Explore** → Prometheus datasource.
3. Query examples:
   - `kube_pxc_backup_status_state` — backup CR state (`Succeeded`, `Failed`, …)
   - `kube_pxc_backup_status_completed` — completion timestamp gauge (validate parsing in Explore)
   - `kube_pxc_backup_info` — backup metadata

4. Pods in `wookie-observability` (default namespace):

```bash
kubectl get pods -n wookie-observability
# expect kube-state-metrics, victoria-metrics-operator, vmagent (names vary by release)
```

5. vmagent remote-write: check vmagent logs for errors posting to `.../victoriametrics/api/v1/write`.

### Backup staleness alert (30 hours)

With KSM metrics in PMM, provision the **`PXC Backup Stale Critical`** rule via
`pxc-pmm-alerts` (PromQL on `kube_pxc_backup_*`). It fires when the newest
`Succeeded` backup’s `kube_pxc_backup_status_completed` is older than **108000s (30h)**,
or when backup CRs exist but none are `Succeeded`. Requires `k8sMonitoring` (or
equivalent vmagent remote-write) on the same PMM instance.

## Verifying

```bash
kubectl logs -n pmm -l app.kubernetes.io/name=pmm-alert-provisioner

curl -sku admin:<password> https://localhost:<port>/v1/alerting/rules \
  | grep -o '"name":"[^"]*"'
```

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

Percona’s [Monitor Kubernetes](https://docs.percona.com/percona-operator-for-mysql/pxc/monitor-kubernetes.html) flow: Victoria Metrics k8s stack with KSM `customResourceState` config (PXC backup CR metrics) remote-writing to PMM.

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
| `pmm-k8s-monitoring` | Helm | `vm/victoria-metrics-k8s-stack` @ `0.30.3` (Percona pin); KSM CR config embedded via `customResourceState` in chart values |

Helm values (copy elsewhere): `k8s-monitoring-helm-values.nix` → `mkValuesYaml`.

`dependsOn` `pmm-server` so PMM exists before vmagent remote-write.

### Deployment order (helmfile and fleet)

Platform batches (lowest `priority` first):

| Batch | Priority | PMM k8s monitoring contents |
|-------|----------|----------------------------|
| `namespaces` | 100 | observability namespace (if declared) |
| **`crds`** | **200** | **`vm-operator-crds`** — 16 Victoria Metrics Operator CRDs (`vm-operator-crds.nix`) |
| `operators` | 300 | (none for PMM k8s stack; operator ships inside the services chart) |
| `services` | 600 | `pmm-server`, `pmm-k8s-monitoring` (Helm: operator + vmagent + KSM) |

In this repo, **`crds` is the pre-operator batch**. CRDs are cluster-scoped manifests,
not Helm releases. `deploy-helmfile` applies `batches.crds` with `kubectl create`
**before** `helmfile sync`, then waits for CRDs to become `Established`.

**Do not run `helmfile sync` alone** on a fresh cluster — that skips the CRD batch.
Use `deploy-*-helmfile` (e.g. `nix run .#pmm-up` → `pmm-deploy`) or apply the CRD
batch yourself first.

**Fleet:** deploy the `crds` batch GitRepo/wave before `services`. Do not use a single
`renderAllBundles` apply for everything — CRDs must be accepted by the API before
`VMAgent` / `VMServiceScrape` objects. Use per-batch manifests (`kubelib.renderBatchManifests`)
or equivalent wave ordering.

`pmm-k8s-monitoring` `dependsOn` includes `vm-operator-crds` for bundle ordering metadata;
helmfile intentionally excludes the `crds` batch from release `needs` (see `helmfile.nix`).

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
install, etc.). Nix alternative: `k8s-monitoring-helm-values.nix` → `mkValuesYaml`
(includes KSM config; no separate ConfigMap manifest).

### Troubleshooting: `configmap "customresource-config-ksm" not found`

The failing pod is **kube-state-metrics** (volume `cr-config`), not the Victoria
Metrics operator. Helm values that reference an external ConfigMap by name require
you to apply that ConfigMap in the **same namespace** as the release **before**
the KSM pod starts.

**Diagnose:**

```bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS=wookie-observability   # your observability namespace

kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NS" | grep -E 'kube-state|operator'
kubectl --kubeconfig="$KUBECONFIG" describe pod -n "$NS" -l app.kubernetes.io/name=kube-state-metrics
kubectl --kubeconfig="$KUBECONFIG" get configmap customresource-config-ksm -n "$NS"
```

If the ConfigMap is missing: either apply it, or (recommended) embed KSM config in
Helm values via `kube-state-metrics.customResourceState.enabled: true` and
`customResourceState.config` from `ksm-configmap.nix` (see `k8s-monitoring-values.nix`).

**Quick fix (legacy external ConfigMap):**

```bash
cd nix/wookie-nixpkgs/modules/projects/pmm
OUT=$(nix-build -E '
  let pkgs = import <nixpkgs> {}; lib = pkgs.lib; yaml = pkgs.formats.yaml {};
      ksm = import ./ksm-configmap.nix { inherit lib pkgs; };
  in pkgs.runCommand "ksm-cm" {} ''
    mkdir -p $out
    cp ${yaml.generate "manifest.yaml" (ksm.mkKsmConfigMap "'"${NS}"'")} $out/manifest.yaml
  ''
' --no-out-link)
kubectl --kubeconfig="$KUBECONFIG" apply -f "$OUT/manifest.yaml"
kubectl --kubeconfig="$KUBECONFIG" delete pod -n "$NS" -l app.kubernetes.io/name=kube-state-metrics
```

### Troubleshooting: VMAgent `remoteWrite cannot be empty array`

With `vmsingle.enabled: false` and `vmcluster.enabled: false`, the chart sets VMAgent
`spec.remoteWrite` **only** from `externalVM.write.url`. If that URL is empty or missing
from your values, Helm renders `remoteWrite: []` and the operator admission webhook
rejects the CR on upgrade.

**Diagnose rendered values:**

```bash
helm get values vm-operator-wookie -n wookie-observability -a | grep -A6 'write:'
# or before apply:
helm template ... -f your-values.yaml | grep -A15 'kind: VMAgent'
```

You must see a non-empty `remoteWrite[0].url`.

**Fix — set PMM remote-write URL** (adjust service/namespace to match your PMM install):

```yaml
externalVM:
  write:
    url: "https://monitoring-service.pmm.svc.cluster.local/victoriametrics/api/v1/write"
    bearerTokenSecret:
      name: pmm-service-account-token
      key: pmmservertoken
```

Nix (`k8s-monitoring-helm-values.nix`):

```nix
render.mkValuesYaml {
  pmmWriteUrl = "https://monitoring-service.pmm.svc.cluster.local/victoriametrics/api/v1/write";
  k8sClusterId = "pmm-local";
}
```

The token Secret must exist in the **same namespace as vmagent** (default
`wookie-observability`), key `pmmservertoken` with a PMM glsa_… token.

`k8s-monitoring-values.nix` now throws at eval time if `pmmWriteUrl` is empty.

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

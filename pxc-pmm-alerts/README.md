# pxc-pmm-alerts-controller

Daemon that reads alert rule JSON from a `ConfigMap`, resolves the Grafana **MySQL** folder UID (`GET /graph/api/folders`), substitutes `__MYSQL_FOLDER_UID__`, then aligns PMM using **`POST /v1/alerting/rules`** for each rule.

**Important:** PMM Server does **not** expose a usable **`GET /v1/alerting/rules`** list (501 / method not allowed on tested builds). Reconcile behavior:

1. **`template_name` present** (e.g. `pmm_mysql_down`): **`POST /v1/alerting/rules`** (requires `folder_uid`). These land in the Grafana rule group named by the JSON `group` field (default **`pxc-pmm`**).
2. **Custom PromQL (`expr`)** rules: PMM rejects these on `/v1/alerting/rules` without a template; they are provisioned like `projects/pmm/default.nix`: **`POST /graph/api/ruler/grafana/api/v1/rules/{folderUid}`** with one Grafana rule group per alert name.

Each apply **`DELETE`s** the shared template group (`RULE_GROUP_NAME`, default `pxc-pmm`), then **`DELETE`s** each expr rule’s old group (same name as the alert), then reposts everything. By default **`FORCE_SYNC_EVERY_CYCLE=true`**: the controller cannot list existing rules in PMM, so it re-applies on every interval to match the ConfigMap (overwriting UI changes). Set **`FORCE_SYNC_EVERY_CYCLE=false`** to skip when `rules.json` bytes are unchanged (SHA-256) and the last apply for that digest succeeded (saves API load; PMM drift is not repaired).

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `PMM_URL` | `https://monitoring-service.pmm.svc.cluster.local` | PMM / Grafana base URL (no trailing slash). The `percona/pmm` chart names the Service `monitoring-service` (not `pmm`). |
| `RULE_GROUP_NAME` | `pxc-pmm` | Must match the `group` field in every rule in `rules.json` (Grafana rule group; used for ruler `DELETE` before reposting). |
| `FORCE_SYNC_EVERY_CYCLE` | `true` | If `true`, re-applies every loop when `rules.json` is unchanged so **UI edits/deletes** are overwritten (PMM has no reliable rules list API). Set `false` to skip until the ConfigMap changes (less API load; drift is not healed). |
| `PMM_USER` | (prompt if unset) | Basic auth user; chart default is `admin`. |
| `PMM_PASSWORD` | (prompt if unset) | Basic auth password. |
| `PMM_INSECURE_TLS` | `true` | When `true`, TLS certificate verification is skipped (typical for in-cluster PMM TLS). |
| `PMM_REQUEST_TIMEOUT_MS` | `15000` | Per-request timeout for PMM HTTP calls. |
| `SYNC_INTERVAL_MS` | `60000` | Sleep between full reconcile loops. |
| `ALERT_RULES_CONFIGMAP` | `pxc-pmm-alert-rules` | ConfigMap name. |
| `ALERT_RULES_KEY` | `rules.json` | Key holding a **JSON array** of rule objects. |

## ConfigMap rule shape

- **Template rule** (same idea as `nix/wookie-nixpkgs/modules/projects/pmm/alerts.nix`): `template_name`, `name`, `group`, `params`, `for`, `severity`, `custom_labels`, `filters`.
- **Custom expr rule**: `name`, `group`, `expr`, `for`, optional `no_data_state`, `custom_labels`, optional `folder_uid` placeholder `__MYSQL_FOLDER_UID__`.

## Kubernetes manifests

The Nix expression emits a **`v1/List` JSON** manifest (no nixpkgs import; `nix-build` stays small on Darwin).

```bash
nix-build pxc-pmm-alerts.nix -A k8sManifest -o /tmp/pxc-pmm-alerts.json
kubectl apply -f /tmp/pxc-pmm-alerts.json
```

The Deployment expects Secret **`pmm-secret`** / key **`PMM_ADMIN_PASSWORD`** (created by the official `percona/pmm` Helm chart).

## Local PMM on k3d (Mac arm64)

Prerequisites: Docker working (e.g. Colima + `qemu` backend if `vz` hangs), `k3d`, `kubectl`, `helm`.

1. If **`kubectl` hangs** with TLS handshake / connection errors: Docker or the k3d API port is not up, or kubeconfig is stale. Run **`/Users/craig/percona_operator/pxc-pmm-alerts/scripts/pmm-k3d-ensure.sh`** (starts or creates `pmm-local` and merges `k3d kubeconfig` so the context `k3d-pmm-local` works). Requires Docker/Colima running.
2. **2–4 min:** Install PMM: `chmod +x /Users/craig/percona_operator/pxc-pmm-alerts/scripts/*.sh && /Users/craig/percona_operator/pxc-pmm-alerts/scripts/install-pmm-k3d.sh` (uses **`image.tag=3.5.0`** for linux/arm64; override with `IMAGE_TAG=...` if needed).
3. **Web UI:** `/Users/craig/percona_operator/pxc-pmm-alerts/scripts/pmm-ui.sh` — preflight (API reachable, `monitoring-service` has endpoints, PMM Ready) then `kubectl port-forward` to `https://127.0.0.1:8443/` (blocks in the foreground; that is expected). **Password:** `kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 -d; echo` (user `admin`).

4. **4–6 min:** Build and load the controller image into k3d, apply manifests, watch logs (`kubectl logs -f deploy/pxc-pmm-alerts-controller -n pmm`).

## Operational note (progress visibility)

During bring-up, poll every **2 minutes**: `kubectl -n pmm get pods`, `kubectl -n pmm describe pod -l ...` if not `Running`. Do not rely on indefinite waits; use `--timeout` on `kubectl`/`helm`/`curl`.

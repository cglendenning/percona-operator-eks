# pxc-pmm-alerts-controller

Daemon that reads alert rule JSON from a `ConfigMap`, resolves the Grafana **MySQL** folder UID (`GET /graph/api/folders`), substitutes `__MYSQL_FOLDER_UID__`, then aligns PMM using **`POST /v1/alerting/rules`** for PMM template rules and **`POST /graph/api/ruler/grafana/api/v1/rules/{folderUid}`** for custom PromQL (`expr`) rules (**one Grafana rule group per expr alert**, named after the rule `name`). **`EXPR_RULE_BATCH_GROUP`** (default **`expression`**) is only used to delete the legacy **batched** expr group from older releases.

### Sync behavior

PMM does not expose a usable **`GET /v1/alerting/rules`** list on many builds (often 501). The controller instead uses Grafana’s ruler API:

- **`GET /graph/api/ruler/grafana/api/v1/rules/{folderUid}`** to read rule groups already in the MySQL folder.

From that snapshot it reconciles **only what differs** from the ConfigMap:

1. **Expr rules** — For each expr rule, compares one ruler group (named like the alert `name`) **semantically** (`interval`, title, `for`, PromQL `expr`, `no_data_state`, labels with Grafana-only keys stripped). Only rules that drift or are missing get **delete + POST**. Orphan expr groups no longer in the ConfigMap are removed; the legacy batched group named **`EXPR_RULE_BATCH_GROUP`** (formerly `from-expression`) is deleted when present.
2. **Template rules** (`template_name` set) — Still **POST**ed through **`POST /v1/alerting/rules`**. The controller stores **`pxc_pmm_managed_digest`** on **`custom_labels`** so ruler GET can detect drift. If PMM returns **400** duplicate title (rule exists but digest/title check did not match), it **deletes** the Grafana ruler group named **`RULE_GROUP_NAME`**, **waits** until the group is gone on the ruler API, then **GET**s **`/graph/api/v1/provisioning/alert-rules`** and **DELETE**s any provisioned rules in the MySQL folder whose **title** matches a ConfigMap template name or is **empty** (stale rows that PMM can still count as conflicts). It then **reposts all** template rules once for that cycle, then continues.

If **`GET` ruler fails** for a cycle, the controller logs the error and **skips apply** for that sync interval (no deletes or posts). The next cycle retries after **`SYNC_INTERVAL_MS`**.

While the ConfigMap bytes are unchanged (same SHA-256 digest as the previous successful UID resolution), the controller **reuses** the cached MySQL folder UID and Grafana datasource UID instead of calling **`GET /graph/api/folders`** and **`GET /graph/api/datasources`** every loop. Edit the ConfigMap or restart the pod if you rename the MySQL folder or change default datasources in Grafana without updating rules.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `PMM_URL` | `https://monitoring-service.pmm.svc.cluster.local` | PMM / Grafana base URL (no trailing slash). The `percona/pmm` chart names the Service `monitoring-service` (not `pmm`). |
| `RULE_GROUP_NAME` | `template` | Must match the `group` field on **template** rules in `rules.json` (Grafana rule group for PMM templates). |
| `EXPR_RULE_BATCH_GROUP` | `expression` | Legacy batched expr group name to delete on upgrade; expr rules are stored **per rule name**, not under this group. |
| `PMM_USER` | (prompt if unset) | Basic auth user; chart default is `admin`. |
| `PMM_PASSWORD` | (prompt if unset) | Basic auth password. |
| `PMM_INSECURE_TLS` | `true` | When `true`, TLS certificate verification is skipped (typical for in-cluster PMM TLS). |
| `PMM_REQUEST_TIMEOUT_MS` | `15000` | Per-request timeout for PMM HTTP calls. |
| `SYNC_INTERVAL_MS` | `60000` | Sleep between reconcile loops. |
| `ALERT_RULES_CONFIGMAP` | `pxc-pmm-alert-rules` | ConfigMap name. |
| `ALERT_RULES_KEY` | `rules.json` | Key holding a **JSON array** of rule objects. |

## Tests

```bash
cd pxc-pmm-alerts
npm test
```

`src/alertSync.test.ts` covers rule parsing, placeholder replacement, Grafana ruler flattening, expr batch semantic equality, template digest/in-sync checks, and **`syncIncremental`** against an in-memory **`PmmClient`** fake (including ruler GET failure, per-rule expr reconcile, template duplicate recovery, and orphaned / legacy expr group cleanup).

## ConfigMap rule shape

- **Template rule** (same idea as `nix/wookie-nixpkgs/modules/projects/pmm/alerts.nix`): `template_name`, `name`, `group` (must match **`RULE_GROUP_NAME`**, default **`template`**), `params`, `for`, `severity`, `custom_labels`, `filters`.
- **Custom expr rule**: `name`, `group` (informational / docs; ruler group is **the rule `name`**), `expr`, `for`, optional `no_data_state`, `custom_labels`, optional `folder_uid` placeholder `__MYSQL_FOLDER_UID__`.

The controller adds **`pxc_pmm_managed_digest`** to **`custom_labels`** when posting template rules; do not rely on setting that key yourself.

### Limitations

- **Template rules:** Sync uses a **digest of ConfigMap-controlled fields** plus the Grafana alert title. Edits in the PMM/Grafana UI that leave those fields (and the managed digest label) unchanged may **not** trigger a resync until you change `rules.json`. Expr rules are compared on **title, for, expr, no_data_state, and non-injected labels**; changes only to Grafana-only query metadata may not trigger a repost until something in that set differs.

## Kubernetes manifests

The Nix expression emits a **`v1/List` JSON** manifest (no nixpkgs import; `nix-build` stays small on Darwin).

```bash
nix-build pxc-pmm-alerts.nix -A k8sManifest -o /tmp/pxc-pmm-alerts.json
kubectl apply -f /tmp/pxc-pmm-alerts.json
```

The Deployment expects Secret **`pmm-secret`** / key **`PMM_ADMIN_PASSWORD`** (created by the official `percona/pmm` Helm chart).

## Local PMM on k3d (Mac arm64)

Use a single script from **`pxc-pmm-alerts/`**: **`npm test`** → k3d cluster **`pmm-local`** → Helm PMM → **`docker buildx`** image **`pxc-pmm-alerts-controller:latest`** → **`k3d image import`** → **`nix-build … k8sManifest`** + **`kubectl apply`** → **`rollout restart`** + wait for **`deployment/pxc-pmm-alerts-controller`** → **`kubectl port-forward`** to **`https://127.0.0.1:8443/`** (foreground until Ctrl-C).

**macOS:** use **Colima** as the container engine only. The script runs **`docker context use colima`** and clears **`DOCKER_HOST`** if it pointed at another daemon. Install **`colima`** and **`docker`** (**Homebrew**). Do not rely on Docker Desktop for this workflow. **`PMM_LOCAL_ALLOW_NON_COLIMA=1`** skips the macOS Colima enforcement (Linux is unchanged: no Colima requirement).

```bash
chmod +x scripts/pmm-local.sh
./scripts/pmm-local.sh
```

If **`docker info`** (against Colima on Mac) does not succeed, the script runs **`colima start`** once (set **`PMM_LOCAL_AUTO_COLIMA=0`** to skip). If the engine is still down, it **exits 0** after tests (skips k3d/PMM) so a local run is not a spurious failure. Set **`PMM_LOCAL_REQUIRE_DOCKER=1`** in **CI** to fail when the engine is missing. If the **`vz`** VM type hangs on arm64, try **`colima start --vm-type=qemu`**. **`docker info`** is capped at **`DOCKER_INFO_TIMEOUT`** (default **30s**, max **120s**) when **`timeout`** exists. Set **`PMM_LOCAL_TEST_ONLY=1`** to run **`npm test`** and exit without checking the engine.

**Prerequisites:** **`docker`** CLI + **`docker buildx`** (served by Colima on Mac), **`k3d`**, **`kubectl`**, **`helm`**, **`npm`**, **`nix-build`**. For **linux/arm64** PMM images, the script defaults **`IMAGE_TAG=3.5.0`** unless you override it. Default admin password: **`PMM_BOOTSTRAP_PASSWORD`** (default `pmm-local-dev`); chart Secret **`pmm-secret`**. Override kube context with **`KUBECTL_CONTEXT`** (default **`k3d-pmm-local`**). Local listen port: **`PMM_LOCAL_PORT`** (default **8443**). If that TCP port is already in use on **`127.0.0.1`**, the script picks the next free port up to **`PMM_LOCAL_PORT + PMM_LOCAL_PORT_SCAN`** (default scan window **40**).

Set **`PMM_LOCAL_SKIP_CONTROLLER=1`** to skip building/importing the controller and manifest apply (PMM + port-forward only). Tune controller rollout polling with **`DEPLOY_ROLLOUT_MAX_SLICES`** (default **60**) and **`ROLL_SLICE`**.

If the script **stops printing right after Vitest finishes**, the **Docker daemon (Colima) is usually not answering** on the socket: the script now caps every **`docker`** call at **`DOCKER_INFO_TIMEOUT`** seconds (default **30**, max **120**) so it cannot hang indefinitely. Raise the cap if `docker info` is legitimately slow. Recovery: **`colima stop && colima start`** (or reboot Colima’s VM).

## Operational note (timeouts and progress)

`scripts/pmm-local.sh` follows **`.cursor/rules/percona-operator.mdc`**: no single **kubectl** wait exceeds **30s**; progress is printed between slices. Long **k3d** / **helm** / **nix-build** / **k3d image import** steps print a **heartbeat every 20s** (override with **`PMM_LOCAL_HEARTBEAT_SEC`**). **`k3d cluster list`** is capped at **`K3D_CLUSTER_LIST_TIMEOUT`** (default **5s**); on timeout the script assumes a wedged Docker API and, on macOS with **Colima** and **`PMM_LOCAL_AUTO_COLIMA`**, runs **`colima stop`** (≤**10s**) then **`colima start`**, then retries once. **`k3d version`** uses **`K3D_CLI_TIMEOUT`** (default **30s**) as a **preflight** before creating or starting the cluster.

Tune **`ROLL_SLICE`** (default `30s`), **`PMM_ROLLOUT_MAX_SLICES`**, **`DEPLOY_ROLLOUT_MAX_SLICES`**, **`K3D_API_POLL_MAX`**. **`K3D_CLUSTER`** defaults to **`pmm-local`** → kubectl context **`k3d-pmm-local`**; use another name only if you intentionally named the k3d cluster differently.

**Before PMM:** Colima must be running (**`docker info`** succeeds). If **`kubectl cluster-info`** against **`k3d-pmm-local`** fails with connection refused, the k3d cluster is stopped — run **`colima start`**, then **`k3d cluster start pmm-local`** (or delete/recreate the cluster).

# WORM S3 sample (platform + project Nix modules)

This directory is a **standalone Flake** that demonstrates how **platform** rules (Object Lock defaults, reference IAM denies) combine with a **project** declaration (bucket name, Helm merge) to produce:

- a **SeaweedFS Helm `values.yaml`** fragment suitable for k3d / Helm installs aligned with `nix/wookie-nixpkgs` chart usage (`seaweedfs-tutorial` style), and
- a **reference writer IAM JSON** document for app credentials (attach in your real IdP / IRSA / etc.; SeaweedFS IAM may differ slightly from AWS).

## Layout

| Path | Role |
|------|------|
| `modules/platform-s3-worm.nix` | Platform: WORM defaults, `writerIamPolicyJsonFor`, `seaweedHelmFilerS3For`. |
| `modules/project-worm-sample.nix` | Project: bucket name + merged SeaweedFS Helm values + rendered YAML path. |
| `eval-config.nix` | Evaluates modules for the bundled sample (`worm-compliance-sample` bucket). |
| `scripts/static-verify.sh` | No cluster: validates YAML + IAM policy shape (includes a **negative** check: writer must not `Allow` `s3:DeleteObject`). |
| `scripts/k3d-e2e.sh` | k3d + Helm SeaweedFS 4.0.406: Fluentd S3 [audit](https://github.com/seaweedfs/seaweedfs/wiki/S3-API-Audit-log) forward receiver + **positive** put/retention/get; **negative** `delete-object --version-id` (AWS: denied under COMPLIANCE; SeaweedFS may allow — **warns** by default, `WORM_S3_E2E_STRICT_VERSION_DELETE`). |

## Prerequisites

- **Nix** with Flakes (`nix flake`).
- This repo must **track these files in Git** (Nix refuses untracked flake sources inside a Git repo). From repo root:

  `git add nix/projects/worm-s3-sample`

- **For k3d integration only:** A running container engine (Docker / Colima) + enough RAM/CPU for a small k3d cluster; `k3d`, `kubectl`, and **Helm 3.16+** (via Nix) are supplied by the flake app. The app sets `WORM_HELM` to the Nix `helm` so an older `helm` on your `PATH` cannot break chart templates that use `fromToml` (SeaweedFS 4.0.406).

## Commands (macOS, Linux, WSL)

Run from this directory:

```bash
cd nix/projects/worm-s3-sample
```

### Static checks (no Docker)

Runs `yq`/`jq` validation and a **negative** IAM simulation (writer policy must not grant unconditional delete).

```bash
nix run .#worm-static-verify
```

Or the full flake test matrix (builds static check per system):

```bash
nix flake check
```

### Rendered artifacts (inspect only)

**Helm values** (SeaweedFS `filer.s3` with Object Lock bucket):

```bash
nix build .#worm-seaweed-helm-values
cat result/values.yaml
```

Or:

```bash
nix run .#worm-show-helm-values
```

**Writer IAM reference JSON:**

```bash
cat "$(nix build .#worm-writer-iam-policy --no-link --print-out-paths)"
```

Or:

```bash
nix run .#worm-show-writer-iam
```

### k3d + SeaweedFS end-to-end

Creates a throwaway cluster `worm-s3-sample`, applies a small [Fluentd](https://www.fluentd.org/) `in_forward` deployment (port **24224**) that matches the [S3 API audit](https://github.com/seaweedfs/seaweedfs/wiki/S3-API-Audit-log) / Logstash `codec => fluent` story; **Fluent Bit** often does not accept SeaweedFS’s forward wire format. Generated values: `filer.s3.auditLogConfig` host `worm-s3-audit-fluent`, port `24224`. Then installs `seaweedfs/seaweedfs` chart **4.0.406**, port-forwards the filer S3 port, then:

1. **Positive:** `put-object`, `put-object-retention` (COMPLIANCE), `get-object-retention`, `get-object` with `--version-id`.
2. **Negative (AWS S3):** `delete-object --version-id` on a COMPLIANCE-protected version is **AccessDenied**. **SeaweedFS** has historically differed; the e2e **warns** and exits 0 if delete succeeds, unless you set `WORM_S3_E2E_STRICT_VERSION_DELETE=1` (CI / parity gate). See [seaweedfs#8350](https://github.com/seaweedfs/seaweedfs/issues/8350) and [PR#8351](https://github.com/seaweedfs/seaweedfs/pull/8351) for upstream discussion.

```bash
nix run .#worm-k3d-e2e
```

Cleanup is automatic unless you set `WORM_KEEP_CLUSTER=1`. At the end of the S3 tests, the script prints **`kubectl logs`** from the `worm-s3-audit-fluent` deployment (up to 2000 lines) so the run shows a sample audit trail. Override manifest path with **`WORM_AUDIT_FLUENT_MANIFEST`** (the flake points at `scripts/worm-s3-audit-fluent.k8s.yaml`); override wait with **`WORM_S3_AUDIT_FLUENT_WAIT`**.

**S3 auth + audit file:** the sample sets **`filer.s3.enableAuth: true`**. The SeaweedFS Helm chart only mounts `/etc/sw` (including `filer_s3_auditLogConfig.json` from the `seaweedfs-s3-secret` hook) when `enableAuth` is true, so the filer can load S3 auth config and the audit forward JSON. The e2e loads **admin** keys from that secret for `aws` (dummy creds are invalid once auth is on). If you set **`auditLogConfig` without `enableAuth`**, the chart does not mount the file while the filer is still given `-s3.auditLogConfig=...`, so no audit events reach Fluent. **`auditLogConfig.timeout`** must follow **github.com/fluent/fluent-logger-golang**’s `time.Duration` JSON rules: a bare number is **nanoseconds** (e.g. `3` seconds = `3000000000`), not milliseconds like the Seaweed wiki’s example `3000`—`3000` would be 3µs and breaks the client.

**Note:** SeaweedFS S3 object-lock and delete semantics can differ from AWS (delete marker vs `AccessDenied`, and whether `delete-object --version-id` is blocked under COMPLIANCE). This sample still **verifies** retention and read-before-delete; the **versioned delete** step is a **soft** negative by default. The e2e may **not** get `VersionId` from the `put-object` body alone; it uses `head-object` and `list-object-versions` with parsing that ignores a bogus `VersionId` of the **string** `"null"`. The script also calls **`s3api put-bucket-versioning` / `get-bucket-versioning`** so the bucket is *actually* in `Status=Enabled` (Helm `createBuckets` alone can leave the filer entry without the versioning extended attribute, which yields only null versions until fixed).

#### If `nix run .#worm-k3d-e2e` seems to hang (especially on macOS)

Long pauses are usually normal until you see the next `==>` line.

**If every `k3d` command (including `k3d cluster list` in another terminal) hangs** with no output, the **container engine** is usually not responding. For Docker Desktop: quit the app and start it again. For **Colima:** `colima start`. Then `timeout 20 docker info` and `timeout 20 k3d version` must return. A runaway `k3d cluster create --wait` without a max duration can also keep the engine busy so other k3d clients look frozen.

**Timeouts are tight by design** so failures surface quickly. On a slow network or first-time image pulls, increase values (for example `WORM_HELM_WAIT_TIMEOUT=15m`).

1. **Docker:** `WORM_DOCKER_INFO_TIMEOUT` (default **20s**).
2. **k3d create:** `WORM_K3D_WAIT_TIMEOUT` (default **10m**); see `k3d cluster create --help` (`--wait` is always capped).
3. **k3d delete / kubeconfig / exit cleanup:** `WORM_K3D_DELETE_TIMEOUT_SEC` (default **60s**), `WORM_K3D_KUBECONFIG_TIMEOUT_SEC` (default **30s**), `WORM_K3D_CLEANUP_DELETE_SEC` (default **60s** for `trap` delete).
4. **Optional:** skip k3d readiness wait (Helm may race the API): `WORM_K3D_NOWAIT=1 nix run .#worm-k3d-e2e` — the create still uses `--timeout` to avoid a total hang.
5. **Helm:** `WORM_HELM_WAIT_TIMEOUT` (default **8m**; raise for SeaweedFS image pull on a cold machine); `WORM_HELM_REPO_UPDATE_SEC` (default **30s**) for `helm repo update`. While `helm --wait` runs, the script prints one-line help, then (unless `WORM_HELM_LIVE_STATUS=0`) periodic `kubectl get deploy,sts,po` and PVCs every `WORM_HELM_STATUS_INTERVAL` (default **8s**). `WORM_HELM_DEBUG=1` adds `helm --debug`.
6. **kubectl wait:** `WORM_KUBECTL_NODE_WAIT` (default **60s**) for **nodes** Ready; `WORM_FILER_POD_WAIT` (default **120s**) for the filer pod.
7. **`metrics.k8s.io` / `E0426 memcache` lines:** the script prunes and reinstalls [metrics-server](https://github.com/kubernetes-sigs/metrics-server) (server-side apply with **force-conflicts**), then **json-patches** `--kubelet-insecure-tls` and **fails the run** if the `metrics-server` container args do not contain that flag (k3d requires it). It then `kubectl rollout status`, blocks until **`kubectl get --raw /apis/metrics.k8s.io/v1beta1`**, with `WORM_METRICS_ROLLOUT_TIMEOUT_SEC` (default **60s**) and `WORM_METRICS_API_WAIT_SEC` (default **40s**). **`WORM_K8S_QUIET_DISCOVERY=1`** (default) filters noisy memcache log lines. Use `WORM_SKIP_METRICS_SERVER=1` only when air-gapped.
8. **S3 / AWS calls:** `WORM_PF_READY_SECONDS` (default **40**). Per-call limits: `WORM_AWS_CONNECT_TIMEOUT` (default **5s**) and `WORM_AWS_READ_TIMEOUT` (default **20s**). For COMPLIANCE + `delete-object --version-id`, set **`WORM_S3_E2E_STRICT_VERSION_DELETE=1`** to fail the run if delete returns success (AWS-denies / strict parity); default **0** logs warnings if SeaweedFS allows the delete. **`WORM_S3_VERSION_ID_RETRIES`** / **`WORM_S3_VERSION_ID_SLEEP`**: list-after-put `VersionId` resolution.
9. **Verbose shell trace:** `WORM_DEBUG=1 nix run .#worm-k3d-e2e`
10. **Port-forward log:** `tail -f /tmp/worm-pf.log`

## Reusing in your real project

1. Import `modules/platform-s3-worm.nix` from a shared platform flake or path.
2. In the app / tenant project module, set `projects.wormS3Sample.enable` (or copy the pattern with your own option namespace), `bucketName`, and merge `platform.s3Worm.seaweedHelmFilerS3For bucket` into your SeaweedFS Helm values.
3. Attach `platform.s3Worm.writerIamPolicyJsonFor bucket` (or the structured policy) to the credentials your workloads use.

## Related repo material

- Broader SeaweedFS + k3d flow: `seaweedfs_tutorial/README.md` and `nix run` targets under `nix/wookie-nixpkgs` (`seaweedfs-up`, `seaweedfs-down`).

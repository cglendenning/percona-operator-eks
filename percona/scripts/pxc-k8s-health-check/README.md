# PXC Kubernetes namespace health check

Read-only TypeScript CLI that queries `kubectl` and reports likely causes of Percona XtraDB Cluster (PXC) issues on Kubernetes—including symptoms such as the operator message **"get primary pxc pod: failed to get proxy connection … connection refused"**.

It **does not change** any cluster state.

## Requirements

- **Node.js** 18+ (WSL, Linux, or macOS)
- **`kubectl`** on your `PATH`
- A valid kubeconfig; this tool always passes **`--kubeconfig="$KUBECONFIG"`** to every `kubectl` invocation (your shell must set `KUBECONFIG`)

## Install and build

```bash
cd percona/scripts/pxc-k8s-health-check
npm install
npm run build
```

## Usage (WSL example)

```bash
export KUBECONFIG=/mnt/c/Users/<you>/.kube/config   # or your kubeconfig path
node dist/cli.js <namespace>
```

Example:

```bash
export KUBECONFIG=/mnt/c/Users/<you>/.kube/config
node dist/cli.js percona
```

### Help

```bash
node dist/cli.js --help
```

## Exit codes

| Code | Meaning |
|------|--------|
| 0 | No checks reported `fail` severity (warnings/info may still appear) |
| 1 | Usage error, missing `KUBECONFIG`, or unexpected exception |
| 2 | At least one finding with severity `fail` |

## What it checks (high level)

- Namespace exists and is readable
- `PerconaXtraDBCluster` CRs: `status.state`, `status.message`, HAProxy / PXC ready counts vs size
- Pods whose names look like PXC / HAProxy: phase, container readiness, waiting states
- **Services and Endpoints** for DB-related ports/names (empty endpoints → common source of connection refused)
- PVC phases
- Presence of NetworkPolicies (informational)
- Recent **Warning** events
- Optional: PXC operator pods cluster-wide (if RBAC allows `-A`)

## Output

1. **Findings** — each line tagged `FAIL` / `WARN` / `INFO` / `OK`
2. **Summary** — one-line health verdict
3. **Prescriptions** — probable root cause plus **copy/paste** `kubectl` commands (all use `--kubeconfig="$KUBECONFIG"`). Review before running in production.

## Limitations

- Heuristic only; your platform may use different labels or Service names.
- Operator pod discovery uses a common label; your install may differ.
- Does not run port-forward or exec into pods (fully read-only).

## Percona version

Aligned with typical **Percona XtraDB Cluster 8.4.x** deployments using the **PXC Kubernetes operator** (`pxc.percona.com` APIs). Adjust expectations if you use ProxySQL instead of HAProxy or a heavily customized chart.

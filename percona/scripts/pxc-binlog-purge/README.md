# pxc-binlog-purge

TypeScript CLI that connects to Kubernetes, finds Percona XtraDB Cluster (PXC) pods, and runs **`PURGE BINARY LOGS`** on **each Running pod**. Binary logs are local to each `mysqld` instance, so purging on every node is what actually frees space everywhere.

## Prerequisites

- **Node.js** 18 or newer (macOS, Linux, or WSL)
- **`kubectl`** on `PATH`, able to reach the cluster
- **`KUBECONFIG`** set to your kubeconfig file (this repo’s convention for scripts is explicit `--kubeconfig` via env)
- Kubernetes **Secret** holding the MySQL **root** password under key **`root`**

Always pass `--kubeconfig` indirectly by setting **`KUBECONFIG`**, never rely on an implicit kube context.

Example (WSL):

```bash
export KUBECONFIG=/mnt/c/Users/you/.kube/config
```

## Install and build

This package ships a **`package-lock.json`** so **`npm ci`** works (reproducible installs on macOS and WSL).

```bash
cd percona/scripts/pxc-binlog-purge
npm ci
npm run build
```

If you do not have a lockfile yet, run `npm install` once to generate one, then prefer `npm ci` afterward.

## Usage

```text
node dist/cli.js --namespace <ns> --secret <secret-name> [--cluster <name>] [--minutes <n>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--namespace` / `-n` | Yes | Namespace where PXC pods run |
| `--secret` / `-s` | Yes | Secret containing MySQL root password (data key **`root`**) |
| `--cluster` / `-c` | Usually | PXC logical name (`app.kubernetes.io/instance`). Required if **more than one** PXC instance exists in the namespace |
| `--minutes` / `-m` | No | Logs older than this many whole minutes are purged (**default: 5**) |

Pods are selected with:

`app.kubernetes.io/name=percona-xtradb-cluster,app.kubernetes.io/component=pxc`

(and `app.kubernetes.io/instance=<cluster>` when `--cluster` is set.)

If **`--cluster` is omitted** and the namespace contains **multiple** distinct instance labels, the tool **errors** instead of guessing.

### Example

```bash
export KUBECONFIG=~/.kube/config
cd percona/scripts/pxc-binlog-purge
npm ci
npm run build
node dist/cli.js --namespace percona --secret cluster1-secrets --cluster cluster1 --minutes 5
```

The tool prints baseline **`df`** usage for `/var/lib/mysql` per pod, runs the purge, then prints usage again with an approximate freed amount.

### Verify pod and namespace

If `kubectl exec` reports `pods "..." not found`, confirm the pod exists **in that namespace**:

```bash
kubectl --kubeconfig="$KUBECONFIG" get pod -n "<namespace>"
```

Internally, the script passes `-n` before the `exec` subcommand so the namespace applies correctly to every call.

## Safety notes

- Use **`PURGE BINARY LOGS`** rather than deleting binlog files on disk.
- Aggressive retention can hurt **point-in-time recovery** and replicas that still need older binlogs; tune `--minutes` and your operational retention policy accordingly.
- Percona Toolkit does **not** provide a dedicated “purge binlogs” tool; this uses MySQL’s native statement.

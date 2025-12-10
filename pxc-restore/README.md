# PXC Point-in-Time Restore

A complete solution for restoring Percona XtraDB Cluster (PXC) to any point in time. Includes a REST API backend, web UI, and CLI - all calling the same API.

## Features

- List all backups in a source namespace
- Show earliest and latest restorable times based on PITR binlog uploads
- Point-in-time restore to any moment within the restorable window
- Clone cluster configuration from source to target namespace
- Automatic namespace creation
- Post-restore database summary with table counts
- No modifications to source cluster or namespace

## Architecture

```
+----------------+     +----------------+     +------------------+
|   Web UI       |     |      CLI       |     |  Direct API      |
|  (browser)     |     |  (pxc-restore) |     |  (curl/scripts)  |
+-------+--------+     +-------+--------+     +--------+---------+
        |                      |                       |
        +----------------------+-----------------------+
                               |
                        +------v------+
                        |  REST API   |
                        |  (Go)       |
                        +------+------+
                               |
                        +------v------+
                        |  kubectl    |
                        |  (K8s API)  |
                        +-------------+
```

## Quick Start

### Prerequisites

- Go 1.21+
- kubectl configured with cluster access
- jq (for CLI)
- curl (for CLI)

### Start the Server

```bash
cd pxc-restore
./start.sh
```

The server starts on port 8081 by default. Open http://localhost:8081 for the web UI.

### Use the CLI

```bash
# Make executable (first time only)
chmod +x cli/pxc-restore

# Run interactive restore
./cli/pxc-restore -n percona

# Or install globally
make install-cli
pxc-restore -n percona
```

### Use the Web UI

1. Open http://localhost:8081
2. Enter source namespace
3. Select a backup
4. Choose restore time (within the shown range)
5. Enter target namespace
6. Confirm and start restore
7. View restoration summary

## API Endpoints

### List Backups

```bash
GET /api/backups?namespace={namespace}
```

Returns all completed backups with their restorable time windows.

**Response:**
```json
{
  "namespace": "percona",
  "clusterName": "pxc-cluster",
  "backups": [
    {
      "name": "daily-backup-20250115",
      "state": "Succeeded",
      "completed": "2025-01-15T02:00:00Z",
      "pitrReady": true,
      "latestRestorableTime": "2025-01-15T14:30:00Z",
      "storage": "minio-backup"
    }
  ],
  "earliestRestorableTime": "2025-01-15 02:00:00",
  "latestRestorableTime": "2025-01-15 14:30:00",
  "timeFormat": "YYYY-MM-DD HH:MM:SS (UTC)"
}
```

### Check Namespace

```bash
GET /api/namespace/check?namespace={namespace}
```

Validates if a target namespace exists and if it already has a PXC cluster.

### Create Namespace

```bash
POST /api/namespace/create
Content-Type: application/json

{"namespace": "my-restore-ns"}
```

### Start Restore

```bash
POST /api/restore
Content-Type: application/json

{
  "sourceNamespace": "percona",
  "targetNamespace": "percona-restored",
  "backupName": "daily-backup-20250115",
  "restoreTime": "2025-01-15 14:30:00",
  "createNamespace": false
}
```

### Check Restore Status

```bash
GET /api/restore/status?namespace={namespace}&name={restoreName}
```

### Get Restore Summary

```bash
GET /api/restore/summary?namespace={namespace}&cluster={clusterName}
```

Returns database names and table counts after restore.

### Get Cluster Status

```bash
GET /api/cluster/status?namespace={namespace}&cluster={clusterName}
```

## CLI Usage

```
PXC Point-in-Time Restore CLI

Usage: pxc-restore [OPTIONS]

OPTIONS:
    -n, --namespace NAMESPACE   Source namespace containing the PXC cluster
    -a, --api-url URL           API server URL (default: http://localhost:8081)
    -v, --verbose               Enable verbose output
    -h, --help                  Show this help message

ENVIRONMENT VARIABLES:
    PXC_RESTORE_API             API server URL

EXAMPLES:
    # Interactive restore
    pxc-restore -n percona

    # Using a different API server
    pxc-restore -n percona -a http://restore-api:8081
```

## Time Format

All times are in **UTC**. The expected format is:

```
YYYY-MM-DD HH:MM:SS
```

Example: `2025-01-15 14:30:00`

## How It Works

1. **List Backups**: Queries `PerconaXtraDBClusterBackup` resources to find all completed backups with their `latestRestorableTime`

2. **Clone Cluster**: Copies the source cluster's `PerconaXtraDBCluster` spec to the target namespace, adjusting the name and namespace

3. **Copy Secrets**: Automatically copies cluster secrets and backup credentials to the target namespace

4. **Create Restore**: Creates a `PerconaXtraDBClusterRestore` resource with PITR configuration pointing to the selected backup and restore time

5. **Monitor Progress**: Polls restore and cluster status until completion

6. **Summary**: Queries the restored MySQL instance for database and table counts

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| PORT | 8081 | Server port |
| KUBECONFIG | (default) | Path to kubeconfig file |
| PXC_RESTORE_API | http://localhost:8081 | API URL for CLI |

### Server Options

Set the port:
```bash
PORT=9090 ./start.sh
```

Use a specific kubeconfig:
```bash
KUBECONFIG=/path/to/kubeconfig ./start.sh
```

## Troubleshooting

### "Cannot connect to API server"

Ensure the server is running:
```bash
./start.sh
```

### "No backups found"

Check that backups exist and are in `Succeeded` state:
```bash
kubectl get pxc-backup -n <namespace>
```

### "Restore failed"

Check the restore resource status:
```bash
kubectl describe pxc-restore <restore-name> -n <namespace>
```

Check operator logs:
```bash
kubectl logs -l name=percona-xtradb-cluster-operator -n <operator-namespace>
```

### "Cannot get database summary"

The cluster may still be initializing. Wait for the cluster to reach `ready` state:
```bash
kubectl get pxc <cluster-name> -n <namespace>
```

## Building

```bash
# Build binary
make build

# Build for multiple platforms
make build-all

# Install CLI globally
make install-cli
```

## Security Notes

- The API server requires kubectl access to the cluster
- Secrets are copied from source to target namespace (required for restore)
- The source cluster is never modified
- Database queries are read-only (information_schema)

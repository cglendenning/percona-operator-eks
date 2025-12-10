# PXC Point-in-Time Restore

A standalone CLI tool for restoring Percona XtraDB Cluster (PXC) to any point in time using PITR backups.

## Features

- List all backups in a source namespace
- Show earliest and latest restorable times based on PITR binlog uploads
- Point-in-time restore to any moment within the restorable window
- Clone cluster configuration from source to target namespace
- Automatic namespace creation
- Post-restore database summary with table counts
- Dry-run mode to verify prerequisites without making changes
- No modifications to source cluster or namespace

## Prerequisites

- `kubectl` - configured with cluster access
- `jq` - for JSON parsing
- Percona XtraDB Cluster operator installed in the cluster
- At least one completed backup with PITR enabled

## Usage

```bash
# Make executable (first time only)
chmod +x pxc-restore

# Interactive restore
./pxc-restore -n percona

# Dry run to verify prerequisites
./pxc-restore -n percona --dry-run

# Non-interactive with all options
./pxc-restore -n percona -t percona-restored -b daily-backup-20250115 -r "2025-01-15 14:30:00"

# Dry run with specific target
./pxc-restore -n percona -t test-restore --dry-run
```

## Options

```
REQUIRED:
    -n, --namespace NAMESPACE   Source namespace containing the PXC cluster

OPTIONS:
    -t, --target NAMESPACE      Target namespace (will prompt if not provided)
    -b, --backup NAME           Backup name (will prompt if not provided)
    -r, --restore-time TIME     Restore time in "YYYY-MM-DD HH:MM:SS" UTC format
    --dry-run                   Show what would be done without making changes
    --kubeconfig PATH           Path to kubeconfig file
    -v, --verbose               Enable verbose output
    -h, --help                  Show this help message
```

## Time Format

All times are in **UTC**. The expected format is:

```
YYYY-MM-DD HH:MM:SS
```

Example: `2025-01-15 14:30:00`

## Workflow

1. **Prerequisites Check**: Verifies kubectl, jq, cluster connectivity, and PXC operator
2. **List Backups**: Shows all completed backups with completion time and latest restorable time
3. **Select Backup**: Choose which backup to restore from
4. **Time Window**: Shows the specific restorable time range for the selected backup:
   - **Earliest**: When the backup completed (can't restore before this)
   - **Latest**: The `latestRestorableTime` based on available binlogs
5. **Choose Time**: Enter a point-in-time within the backup's restorable window
6. **Target Namespace**: Specify where to create the restored cluster (creates if needed)
7. **Confirmation**: Review summary before proceeding
8. **Execute Restore**: Creates cluster, copies secrets, initiates PITR restore
9. **Summary**: Displays databases and table counts in the restored cluster

## Dry Run Mode

Use `--dry-run` to verify everything is in place without making changes:

```bash
./pxc-restore -n percona --dry-run
```

This will:
- Check all prerequisites (kubectl, jq, cluster access, operator, backups)
- Verify the source namespace and cluster exist
- List available backups and their time windows
- Validate the target namespace configuration
- Show exactly what actions would be taken

## Example Session

```
$ ./pxc-restore -n percona --dry-run

=====================================================
  PXC Point-in-Time Restore
=====================================================

*** DRY RUN MODE - No changes will be made ***

=====================================================
  Checking Prerequisites
=====================================================

[OK] kubectl installed: v1.28.0
[OK] jq installed: jq-1.6
[OK] Kubernetes cluster accessible (context: my-cluster)
[OK] Source namespace exists: percona
[OK] Percona XtraDB Cluster operator CRDs installed
[OK] Found PXC cluster in source namespace: pxc-cluster
[OK] Found 3 backup(s) in source namespace

[OK] All prerequisites met

[INFO] Source cluster: pxc-cluster

=====================================================
  Available Backups
=====================================================

#    BACKUP NAME                         STATE      PITR   COMPLETED (UTC)      LATEST RESTORABLE
--------------------------------------------------------------------------------------------------------------
[1]  daily-backup-20250115020000         Succeeded  Yes    2025-01-15 02:00:00  2025-01-15 14:30:00
[2]  weekly-backup-20250112010000        Succeeded  Yes    2025-01-12 01:00:00  2025-01-12 23:59:00
[3]  monthly-backup-20250101013000       Succeeded  No     2025-01-01 01:30:00  N/A

Select backup number [1]: 1
[OK] Selected backup: daily-backup-20250115020000

=====================================================
  Restorable Time Window for Selected Backup
=====================================================

  Earliest (backup completed):  2025-01-15 02:00:00 UTC
  Latest (binlogs available):   2025-01-15 14:30:00 UTC

  You can restore to any point in time between these two timestamps.
  The earliest time is when the backup completed.
  The latest time is based on available binlogs (latestRestorableTime).

  Required format: YYYY-MM-DD HH:MM:SS

Enter restore time [2025-01-15 14:30:00]: 2025-01-15 12:00:00
[OK] Restore time: 2025-01-15 12:00:00 UTC

...

=====================================================
  Dry Run - Actions That Would Be Taken
=====================================================

[DRY-RUN] 1. Copy secrets from percona to percona-restored
[DRY-RUN] 2. Create PXC cluster pxc-cluster-restored in percona-restored
[DRY-RUN] 3. Create restore resource to restore from daily-backup-20250115020000
[DRY-RUN] 4. Restore data to point in time: 2025-01-15 12:00:00

[OK] Dry run complete. All prerequisites verified.
[INFO] Remove --dry-run to perform the actual restore.
```

## How It Works

1. **List Backups**: Queries `PerconaXtraDBClusterBackup` resources to find all completed backups with their `latestRestorableTime` from the status field

2. **Clone Cluster**: Copies the source cluster's `PerconaXtraDBCluster` spec to the target namespace, modifying name and namespace

3. **Copy Secrets**: Copies cluster secrets and backup credentials from source to target namespace

4. **Create Restore**: Creates a `PerconaXtraDBClusterRestore` resource with PITR configuration:
   ```yaml
   apiVersion: pxc.percona.com/v1
   kind: PerconaXtraDBClusterRestore
   spec:
     pxcCluster: <cluster>-restored
     backupName: <selected-backup>
     pitr:
       type: date
       date: "YYYY-MM-DD HH:MM:SS"
       backupSource:
         storageName: <backup-storage>
   ```

5. **Monitor Progress**: Polls restore and cluster status until completion

6. **Summary**: Queries the restored MySQL instance for database and table counts

## Troubleshooting

### "No PXC cluster found"

Ensure the source namespace has a running PXC cluster:
```bash
kubectl get pxc -n <namespace>
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
kubectl get pxc <cluster-name> -n <namespace> -w
```

## Security Notes

- Secrets are copied from source to target namespace (required for restore)
- The source cluster is never modified
- Database queries are read-only (information_schema)
- Root password is only used locally within the target cluster pod

# PXC Point-in-Time Restore

A standalone CLI tool for restoring Percona XtraDB Cluster (PXC) to any point in time using PITR backups.

## Tools

This directory contains two complementary scripts:

- **`pxc-restore`** - Performs point-in-time restores from PITR backups
- **`pitr-timestamp-finder`** - Scans binlogs to find the timestamp just before a destructive operation

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

### Prerequisite Checks

The dry-run performs comprehensive validation:

**Tools & Connectivity:**
- kubectl installed and version
- jq installed (for JSON parsing)
- base64 installed (for secret decoding)
- Kubernetes cluster accessible

**Source Environment:**
- Source namespace exists
- PXC operator CRDs installed
- PXC operator is running
- PXC cluster exists and is in ready state
- Backups exist (and count of succeeded backups)

**Secrets & Credentials:**
- Cluster secrets exist and contain root password
- Backup credentials secret exists
- Backup credentials contain AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY

**Storage & Configuration:**
- Backup storage configured in cluster spec
- Backup bucket and endpoint configured
- PITR enabled on source cluster
- Storage class exists
- Ready nodes available in cluster

**Permissions:**
- Permission to create namespaces (RBAC check)

### Dry Run Validation

After selecting backup, time, and target namespace, dry-run validates:

- Cluster secrets can be found and will be copied
- Backup credentials can be found and will be copied
- Backup storage name matches cluster configuration
- Selected backup is in Succeeded state
- Backup destination/location is known
- Target namespace exists or will be created
- No conflicting cluster with same name in target namespace
- Shows cluster size (PXC nodes, ProxySQL nodes)
- Shows complete restore configuration

### Example Dry Run Output

```
=====================================================
  Dry Run - Detailed Validation
=====================================================

Validating secrets to copy:
[DRY-RUN]   Will copy cluster secret: pxc-cluster-secrets
[DRY-RUN]   Will copy backup credentials: minio-credentials

Validating backup configuration:
[DRY-RUN]   Backup storage 'minio-backup' exists in cluster config
[DRY-RUN]   Backup 'daily-backup-20250115' is in Succeeded state
[DRY-RUN]   Backup location: s3://percona-backups/daily-backup-20250115

Validating target namespace:
[DRY-RUN]   Target namespace 'percona-restored' will be created
[DRY-RUN]   No conflicting cluster named 'pxc-cluster-restored'

Cluster configuration to create:
[DRY-RUN]   PXC nodes: 3
[DRY-RUN]   ProxySQL nodes: 3

=====================================================
  Dry Run - Actions Summary
=====================================================

[DRY-RUN] 1. Copy secrets from percona to percona-restored
[DRY-RUN]    - pxc-cluster-secrets (cluster secrets)
[DRY-RUN]    - minio-credentials (backup credentials)
[DRY-RUN] 2. Create PXC cluster pxc-cluster-restored in percona-restored
[DRY-RUN]    - 3 PXC nodes, 3 ProxySQL nodes
[DRY-RUN] 3. Create PerconaXtraDBClusterRestore resource
[DRY-RUN]    - Restore from backup: daily-backup-20250115
[DRY-RUN]    - Point-in-time: 2025-01-15 12:00:00 UTC
[DRY-RUN] 4. Wait for restore completion and cluster ready state
[DRY-RUN] 5. Display database summary

[OK] Dry run validation complete. All checks passed.
[INFO] Remove --dry-run to perform the actual restore.
```

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

## PITR Timestamp Finder

The `pitr-timestamp-finder` script helps identify the exact timestamp to use for point-in-time recovery after accidental data loss (DROP, DELETE, TRUNCATE).

### Usage

```bash
# Make executable (first time only)
chmod +x pitr-timestamp-finder

# Interactive mode - prompts for all inputs
./pitr-timestamp-finder -n percona

# Scan all pods (recommended if primary may have changed)
./pitr-timestamp-finder -n percona --all-pods -o DROP -t users

# Specify operation and table directly
./pitr-timestamp-finder -n percona -o DROP -d mydb -t users

# Specify exact pod
./pitr-timestamp-finder -n percona -p db-pxc-0 -o DELETE -t orders
```

### Options

```
REQUIRED:
    -n, --namespace NAMESPACE   Namespace containing the PXC cluster

OPTIONS:
    -p, --pod POD               PXC pod name (will prompt to select if not provided)
    -a, --all-pods              Scan all PXC pods (useful if primary changed)
    -o, --operation TYPE        Destructive operation: DROP, DELETE, TRUNCATE
    -d, --database DATABASE     Database name (optional, narrows search)
    -t, --table TABLE           Table name to search for
    --kubeconfig PATH           Path to kubeconfig file
    -h, --help                  Show this help message
```

### PXC Cluster Considerations

In a PXC (Galera) cluster, each node maintains its own binlogs. If the primary (writer) node changed due to a failover, the destructive operation may be recorded in a different pod's binlogs than the current primary.

The script handles this by:
- Listing all available PXC pods
- Prompting you to select a specific pod or scan all pods
- Using `--all-pods` to automatically scan all pods until the operation is found

**Recommendation**: If you're unsure which pod was the primary when the destructive operation occurred, use `--all-pods` to scan all pods.

### How It Works

1. Connects to a PXC pod and lists available binlog files
2. Starting from the newest binlog, displays the timestamp range (earliest and latest events)
3. Asks if the destructive operation occurred within that time range
4. If yes, scans the binlog for the specified operation on the target table
5. Returns the timestamp just BEFORE the destructive operation (1 second prior)
6. If the operation is not in that binlog, moves to the previous one and repeats

### Example Session

```
$ ./pitr-timestamp-finder -n percona

=====================================================
  PITR Timestamp Finder
=====================================================

[INFO] This script helps find the timestamp just before a destructive operation
[INFO] for use with pxc-restore point-in-time recovery.

[WARN] This is a READ-ONLY operation - no data will be modified.

[INFO] Found 3 PXC pod(s) in namespace percona:
    - db-pxc-0
    - db-pxc-1
    - db-pxc-2

[WARN] IMPORTANT: In a PXC cluster, binlogs are local to each pod.
[WARN] If the primary (writer) changed, the destructive operation may be
[WARN] in a DIFFERENT pod's binlogs than the current primary.

Select which pod(s) to scan:
  [0] Scan ALL pods (recommended if unsure)
  [1] db-pxc-0
  [2] db-pxc-1
  [3] db-pxc-2

Enter selection [0-3]: 1
[OK] Selected pod: db-pxc-0

Select the destructive operation to search for:
  [1] DROP TABLE
  [2] DELETE FROM
  [3] TRUNCATE TABLE

Enter selection [1-3]: 1
[OK] Searching for: DROP

Enter database name (optional, press Enter to skip): mydb
[INFO] Filtering by database: mydb

Enter table name: users
[OK] Searching for table: users

=====================================================
  Scanning Binlogs
=====================================================

[INFO] Scanning binlogs on pod: db-pxc-0
[INFO]   Binlog directory: /var/lib/mysql
[INFO]   Found 5 binlog file(s)

[INFO]   Examining binlog: mysql-bin.000005 (1 of 5 from newest)

    Binlog time range:
      Earliest: 2025-01-15 12:00:00
      Latest:   2025-01-15 14:30:00

    Was the DROP on 'users' between these times? [y/n/q]: y
[INFO]     Searching for DROP operation on 'users'...

=====================================================
  Result
=====================================================

  Found timestamp for PITR restore:

  2025-01-15 14:25:32

  Found on pod: db-pxc-0

  This timestamp represents the moment just BEFORE the DROP operation.
  Use this timestamp with pxc-restore for point-in-time recovery:

  pxc-restore -n percona -t <target-namespace> -r "2025-01-15 14:25:32"

[OK] Done.
```

### When Operation Is Not Found

If the operation is not found, the script provides helpful diagnostic information:

```
=====================================================
  Search Complete - NOT FOUND
=====================================================

[ERROR] Could not find 'DROP ... users' in any scanned binlog.

[INFO] Possible reasons:
[INFO]   1. The table name does not match exactly (check spelling, case)
[INFO]   2. Try specifying the database name with -d to narrow the search
[INFO]   3. The operation occurred before the oldest available binlog
[INFO]   4. Binary logging was not enabled at the time of the operation
[INFO]   5. The operation may be in a different pod's binlogs (try --all-pods)

[INFO] Tips:
[INFO]   - Table names are case-sensitive in the binlog
[INFO]   - Try searching without the database name first
[INFO]   - Check if the table ever existed: SHOW TABLES LIKE '%users%'
```

### Combining with pxc-restore

After finding the timestamp with `pitr-timestamp-finder`, use it directly with `pxc-restore`:

```bash
# Find the timestamp before data loss
./pitr-timestamp-finder -n percona -o DROP -d mydb -t users
# Output: 2025-01-15 14:25:32

# Restore to that point in time
./pxc-restore -n percona -t percona-restored -r "2025-01-15 14:25:32"
```

## Security Notes

- Secrets are copied from source to target namespace (required for restore)
- The source cluster is never modified
- Database queries are read-only (information_schema)
- Root password is only used locally within the target cluster pod
- The pitr-timestamp-finder script is read-only and makes no changes to data

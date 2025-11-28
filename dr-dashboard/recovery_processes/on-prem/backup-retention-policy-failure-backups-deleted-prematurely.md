# Backup Retention Policy Failure (Backups Deleted Prematurely) Recovery Process

## Primary Recovery Method

1. **Identify the backup deletion issue**
   ```bash
   # Check backup count
   kubectl get perconaxtradbclusterbackup -n <namespace> --sort-by=.metadata.creationTimestamp
   
   # List backups in MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<backup-bucket>/backups/ --recursive
   
   # Check backup retention policy configuration
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml | grep -A 10 retention
   ```

2. **Restore from remaining backups**
   ```bash
   # Identify available backups
   kubectl get perconaxtradbclusterbackup -n <namespace> -o jsonpath='{.items[*].metadata.name}'
   
   # Verify backup integrity
   kubectl describe perconaxtradbclusterbackup -n <namespace> <backup-name>
   
   # Restore from most recent available backup if needed
   kubectl apply -f <restore-cr.yaml>
   ```

3. **Implement retention policy fixes**
   ```bash
   # Review and fix retention policy configuration
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to fix retention policy
   # Ensure retention period matches compliance requirements
   kubectl apply -f cluster-backup.yaml
   ```

4. **Verify backup lifecycle**
   ```bash
   # Check backup retention settings
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o jsonpath='{.spec.backup.retentionPolicy}'
   
   # Monitor backup creation and deletion
   kubectl get perconaxtradbclusterbackup -n <namespace> -w
   
   # Verify backups are not being deleted prematurely
   ```

5. **Create new backups to restore retention**
   ```bash
   # Trigger immediate full backup
   kubectl apply -f <full-backup-cr.yaml>
   
   # Monitor backup completion
   kubectl get perconaxtradbclusterbackup -n <namespace> -w
   
   # Verify backup is created and stored correctly
   ```

## Alternate/Fallback Method

1. **Recover from secondary DC backups**
   ```bash
   # Check secondary DC for available backups
   # Access secondary DC MinIO or backup storage
   # List available backups
   
   # Restore from secondary DC backup if available
   kubectl apply -f <restore-from-secondary-cr.yaml>
   ```

2. **Restore from off-site archives if available**
   ```bash
   # Check for off-site backup archives
   # Restore from archive to temporary location
   # Import restored backup into cluster
   ```

## Recovery Targets

- **Restore Time Objective**: 4 hours
- **Recovery Point Objective**: 15 minutes
- **Full Repair Time Objective**: 4-12 hours

## Expected Data Loss

Up to RPO if incident occurs during gap

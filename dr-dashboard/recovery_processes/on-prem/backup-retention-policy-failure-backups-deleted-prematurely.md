# Backup Retention Policy Failure (Backups Deleted Prematurely) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -p "Enter PXC cluster name: " CLUSTER_NAME
read -p "Enter MinIO pod name: " MINIO_POD
```





## Primary Recovery Method

1. **Identify the backup deletion issue**
   ```bash
   # Check backup count
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE} --sort-by=.metadata.creationTimestamp
   
   # List backups in MinIO
   kubectl exec -n minio-operator ${MINIO_POD} -- mc ls local/<backup-bucket>/backups/ --recursive
   
   # Check backup retention policy configuration
   kubectl get perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} -o yaml | grep -A 10 retention
   ```

2. **Restore from remaining backups**
   ```bash
   # Identify available backups
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}'
   
   # Verify backup integrity
   kubectl describe perconaxtradbclusterbackup -n ${NAMESPACE} <backup-name>
   
   # Restore from most recent available backup if needed
   kubectl apply -f <restore-cr.yaml>
   ```

3. **Implement retention policy fixes**
   ```bash
   # Review and fix retention policy configuration
   kubectl get perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to fix retention policy
   # Ensure retention period matches compliance requirements
   kubectl apply -f cluster-backup.yaml
   ```

4. **Verify backup lifecycle**
   ```bash
   # Check backup retention settings
   kubectl get perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} -o jsonpath='{.spec.backup.retentionPolicy}'
   
   # Monitor backup creation and deletion
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE} -w
   
   # Verify backups are not being deleted prematurely
   ```

5. **Create new backups to restore retention**
   ```bash
   # Trigger immediate full backup
   kubectl apply -f <full-backup-cr.yaml>
   
   # Monitor backup completion
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE} -w
   
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

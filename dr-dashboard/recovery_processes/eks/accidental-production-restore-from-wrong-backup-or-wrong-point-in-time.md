# Accidental Production Restore from Wrong Backup or Wrong Point in Time Recovery Process

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
```





## Primary Recovery Method

1. **Immediately stop restore if in progress**
   ```bash
   # Check if restore is in progress
   kubectl get perconaxtradbclusterrestore -n ${NAMESPACE}
   kubectl describe perconaxtradbclusterrestore -n ${NAMESPACE} <restore-name>
   
   # Stop restore job if possible
   kubectl delete perconaxtradbclusterrestore -n ${NAMESPACE} <restore-name>
   
   # Check for running restore pods
   kubectl get pods -n ${NAMESPACE} | grep restore
   kubectl delete pod -n ${NAMESPACE} <restore-pod-name>
   ```

2. **Identify correct backup/point in time**
   ```bash
   # List available backups
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE} --sort-by=.metadata.creationTimestamp
   
   # Check backup metadata
   kubectl describe perconaxtradbclusterbackup -n ${NAMESPACE} <backup-name>
   
   # List backups in S3
   aws s3 ls s3://<backup-bucket>/backups/ --recursive
   
   # Verify backup timestamps
   aws s3api head-object --bucket <backup-bucket> --key backups/<backup-name>
   ```

3. **Assess data loss scope**
   ```bash
   # Check current data state
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT MAX(id) FROM <table-name>;"
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT COUNT(*) FROM <table-name>;"
   
   # Compare with expected state
   # Check application logs for data inconsistencies
   # Review audit logs for restore operations
   ```

4. **Restore from correct backup**
   ```bash
   # Create restore CR with correct backup
   kubectl apply -f - <<EOF
   apiVersion: pxc.percona.com/v1
   kind: PerconaXtraDBClusterRestore
   metadata:
     name: <restore-name>
     namespace: ${NAMESPACE}
   spec:
     pxcCluster: ${CLUSTER_NAME}
     backupName: <correct-backup-name>
   EOF
   
   # Monitor restore progress
   kubectl get perconaxtradbclusterrestore -n ${NAMESPACE} <restore-name> -w
   ```

5. **Validate data integrity**
   ```bash
   # Verify data after restore
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT COUNT(*) FROM <table-name>;"
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT MAX(id) FROM <table-name>;"
   
   # Run data integrity checks
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "CHECK TABLE <table-name>;"
   
   # Verify application connectivity
   kubectl exec -n ${NAMESPACE} <app-pod> -- curl -v <database-endpoint>
   ```

6. **Replay transactions from binlogs if available**
   ```bash
   # If restore point is before required time
   # Download binlogs from S3
   aws s3 cp s3://<backup-bucket>/binlogs/<binlog-file> /tmp/
   
   # Identify binlog range needed
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysqlbinlog --start-datetime="<start-time>" --stop-datetime="<stop-time>" <binlog-file>
   
   # Apply binlogs to restore missing transactions
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysqlbinlog <binlog-file> | mysql
   ```

## Alternate/Fallback Method

1. **If restore completed, identify data loss scope**
   ```bash
   # Document what data was lost
   # Identify affected tables and time ranges
   # Notify stakeholders of data loss
   ```

2. **Restore from correct backup**
   ```bash
   # Follow primary recovery method steps 2-5
   ```

3. **Replay transactions from binlogs if available**
   ```bash
   # Follow primary recovery method step 6
   ```

## Recovery Targets

- **Restore Time Objective**: 4 hours
- **Recovery Point Objective**: 15 minutes
- **Full Repair Time Objective**: 4-12 hours

## Expected Data Loss

Up to RPO (15 minutes to hours depending on detection time)

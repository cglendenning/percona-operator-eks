# Backups Complete But Are Non-Restorable (Silent Failure) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter backup bucket name: " BUCKET_NAME
read -p "Enter backup pod name: " BACKUP_POD
read -p "Enter backup deployment name: " BACKUP_DEPLOYMENT
```





## Primary Recovery Method
Detect via scheduled restore drills; fix pipeline; re-run full backup

### Steps

⚠️ **CRITICAL**: This is a backup integrity issue - database may be at risk

1. **Validate current backups immediately**
   ```bash
   # Download latest backup
   aws s3 cp s3://${BUCKET_NAME}/backups/<latest>/ /tmp/verify-backup/ --recursive
   
   # Attempt to prepare backup
   xtrabackup --prepare --target-dir=/tmp/verify-backup
   
   # Check exit code
   echo $?  # Should be 0 for success
   ```

2. **Find last known good backup**
   ```bash
   # List all recent backups
   aws s3 ls s3://${BUCKET_NAME}/backups/ --recursive | grep xtrabackup_checkpoints
   
   # Test each backup going backwards in time
   for backup in $(aws s3 ls s3://${BUCKET_NAME}/backups/ | awk '{print $2}' | tail -10); do
     echo "Testing backup: $backup"
     aws s3 cp s3://${BUCKET_NAME}/backups/${backup}/ /tmp/test-${backup}/ --recursive
     xtrabackup --prepare --target-dir=/tmp/test-${backup}
     if [ $? -eq 0 ]; then
       echo "Valid backup found: $backup"
       break
     fi
   done
   ```

3. **Identify root cause**
   
   **Check backup logs:**
   ```bash
   kubectl logs -n percona ${BACKUP_POD} --tail=500
   ```
   
   **Common issues:**
   - Insufficient disk space during backup
   - Network interruption during S3 upload
   - Wrong xtrabackup version
   - Corrupted source database
   - Clock skew causing issues

4. **Fix the backup pipeline**
   
   **If disk space issue:**
   ```bash
   # Increase PVC size for backup pods
   kubectl patch pvc <backup-pvc> -n percona -p '{"spec":{"resources":{"requests":{"storage":"1Ti"}}}}'
   ```
   
   **If network issue:**
   ```bash
   # Check network policies
   kubectl get networkpolicies -n percona
   
   # Verify S3 connectivity
   kubectl exec -n percona ${BACKUP_POD} -- aws s3 ls s3://${BUCKET_NAME}/
   ```
   
   **If version mismatch:**
   ```bash
   # Check xtrabackup version
   kubectl exec -n percona ${BACKUP_POD} -- xtrabackup --version
   
   # Update to correct version
   kubectl set image deployment/${BACKUP_DEPLOYMENT} backup=percona/percona-xtradb-cluster-operator:1.XX.X
   ```

5. **Re-run full backup immediately**
   ```bash
   # Trigger manual full backup
   kubectl create job --from=cronjob/<backup-cronjob> emergency-backup-$(date +%s) -n percona
   
   # Monitor backup job
   kubectl logs -f job/emergency-backup-* -n percona
   ```

6. **Verify service is restored**
   ```bash
   # Download new backup
   aws s3 sync s3://${BUCKET_NAME}/backups/<new-backup>/ /tmp/verify-new/ --delete
   
   # Prepare and verify
   xtrabackup --prepare --target-dir=/tmp/verify-new
   
   # Verify backup is restorable
   echo $?  # Should be 0 for success
   ```

## Alternate/Fallback Method
Use previous verified backup then roll forward via binlogs

### Steps

1. **Identify last verified backup**
   - Check backup verification log
   - Find last successful restore drill
   - Verify backup date

2. **Restore from last verified backup**
   ```bash
   # Download verified backup
   aws s3 sync s3://${BUCKET_NAME}/backups/<verified-backup>/ /tmp/restore/ --delete
   
   # Prepare backup
   xtrabackup --prepare --target-dir=/tmp/restore
   ```

3. **Apply binlogs for point-in-time recovery**
   ```bash
   # Download binlogs from verified backup time to now
   aws s3 sync s3://${BUCKET_NAME}/binlogs/ /tmp/binlogs/ --exclude "*" --include "mysql-bin.*"
   
   # Apply binlogs
   mysqlbinlog --start-datetime="<backup-time>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p${MYSQL_ROOT_PASSWORD}
   ```

4. **Verify service is restored**
   ```bash
   # Test critical queries
   # Check row counts
   # Verify recent transactions
   ```

# Backups Complete But Are Non-Restorable (Silent Failure) Recovery Process

## Primary Recovery Method
Detect via scheduled restore drills; fix pipeline; re-run full backup

### Steps

⚠️ **CRITICAL**: This is a backup integrity issue - database may be at risk

1. **Validate current backups immediately**
   ```bash
   # Download latest backup from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc cp local/<bucket>/backups/<latest>/ /tmp/verify-backup/ --recursive
   
   # Attempt to prepare backup
   xtrabackup --prepare --target-dir=/tmp/verify-backup
   
   # Check exit code
   echo $?  # Should be 0 for success
   ```

2. **Find last known good backup**
   ```bash
   # List all recent backups
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<bucket>/backups/ --recursive | grep xtrabackup_checkpoints
   
   # Test each backup going backwards in time
   for backup in $(kubectl exec -n minio-operator <minio-pod> -- mc ls local/<bucket>/backups/ | awk '{print $5}' | tail -10); do
     echo "Testing backup: $backup"
     kubectl exec -n minio-operator <minio-pod> -- mc cp local/<bucket>/backups/${backup}/ /tmp/test-${backup}/ --recursive
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
   kubectl logs -n percona <backup-pod> --tail=500
   ```
   
   **Common issues:**
   - Insufficient disk space during backup
   - Network interruption during MinIO upload
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
   
   # Verify MinIO connectivity
   kubectl exec -n percona <backup-pod> -- mc ls local/<bucket>/
   ```
   
   **If version mismatch:**
   ```bash
   # Check xtrabackup version
   kubectl exec -n percona <backup-pod> -- xtrabackup --version
   
   # Update to correct version
   kubectl set image deployment/<backup-deployment> backup=percona/percona-xtradb-cluster-operator:1.XX.X
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
   kubectl exec -n minio-operator <minio-pod> -- mc sync local/<bucket>/backups/<new-backup>/ /tmp/verify-new/ --delete
   
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
   # Download verified backup from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc sync local/<bucket>/backups/<verified-backup>/ /tmp/restore/ --delete
   
   # Prepare backup
   xtrabackup --prepare --target-dir=/tmp/restore
   ```

3. **Apply binlogs for point-in-time recovery**
   ```bash
   # Download binlogs from verified backup time to now
   kubectl exec -n minio-operator <minio-pod> -- mc sync local/<bucket>/binlogs/ /tmp/binlogs/ --exclude "*" --include "mysql-bin.*"
   
   # Apply binlogs
   mysqlbinlog --start-datetime="<backup-time>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p<pass>
   ```

4. **Verify service is restored**
   ```bash
   # Test critical queries
   # Check row counts
   # Verify recent transactions
   ```

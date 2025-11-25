# Backups Complete But Are Non-Restorable (Silent Failure) Recovery Process

## Scenario
Backups complete but are non-restorable (silent failure)

## Detection Signals
- Automated restore test failures
- Checksum mismatches
- Xtrabackup --prepare fails
- Corrupted backup files
- Missing backup metadata
- Inconsistent backup sizes

## Primary Recovery Method
Detect via scheduled restore drills; fix pipeline; re-run full backup

### Steps

⚠️ **CRITICAL**: This is a backup integrity issue - database may be at risk

1. **Validate current backups immediately**
   ```bash
   # Download latest backup
   aws s3 cp s3://<bucket>/backups/<latest>/ /tmp/verify-backup/ --recursive
   
   # Attempt to prepare backup
   xtrabackup --prepare --target-dir=/tmp/verify-backup
   
   # Check exit code
   echo $?  # Should be 0 for success
   ```

2. **Check backup integrity**
   ```bash
   # Verify checksums
   cd /tmp/verify-backup
   xtrabackup --prepare --target-dir=.
   
   # Check for corruption
   ls -lh
   cat xtrabackup_checkpoints
   cat xtrabackup_info
   ```

3. **Find last known good backup**
   ```bash
   # List all recent backups
   aws s3 ls s3://<bucket>/backups/ --recursive | grep xtrabackup_checkpoints
   
   # Test each backup going backwards in time
   for backup in $(aws s3 ls s3://<bucket>/backups/ | awk '{print $2}' | tail -10); do
     echo "Testing backup: $backup"
     aws s3 cp s3://<bucket>/backups/${backup}/ /tmp/test-${backup}/ --recursive
     xtrabackup --prepare --target-dir=/tmp/test-${backup}
     if [ $? -eq 0 ]; then
       echo "✓ Valid backup found: $backup"
       break
     fi
   done
   ```

4. **Identify root cause**
   
   **Check backup logs:**
   ```bash
   kubectl logs -n percona <backup-pod> --tail=500
   ```
   
   **Common issues:**
   - Insufficient disk space during backup
   - Network interruption during S3 upload
   - Wrong xtrabackup version
   - Corrupted source database
   - Clock skew causing issues

5. **Fix the backup pipeline**
   
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
   kubectl exec -n percona <backup-pod> -- aws s3 ls s3://<bucket>/
   ```
   
   **If version mismatch:**
   ```bash
   # Check xtrabackup version
   kubectl exec -n percona <backup-pod> -- xtrabackup --version
   
   # Update to correct version
   kubectl set image deployment/<backup-deployment> backup=percona/percona-xtradb-cluster-operator:1.XX.X
   ```

6. **Re-run full backup immediately**
   ```bash
   # Trigger manual full backup
   kubectl create job --from=cronjob/<backup-cronjob> emergency-backup-$(date +%s) -n percona
   
   # Monitor backup job
   kubectl logs -f job/emergency-backup-* -n percona
   ```

7. **Verify new backup is restorable**
   ```bash
   # Download new backup
   aws s3 sync s3://<bucket>/backups/<new-backup>/ /tmp/verify-new/ --delete
   
   # Prepare and verify
   xtrabackup --prepare --target-dir=/tmp/verify-new
   
   # Test partial restore (don't do full restore on production!)
   xtrabackup --copy-back --target-dir=/tmp/verify-new --datadir=/tmp/test-restore
   ```

8. **Update backup retention**
   - Keep last known good backup indefinitely until new verified backups exist
   - Don't let automated cleanup delete verified backups

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
   aws s3 sync s3://<bucket>/backups/<verified-backup>/ /tmp/restore/ --delete
   
   # Prepare backup
   xtrabackup --prepare --target-dir=/tmp/restore
   ```

3. **Apply binlogs for point-in-time recovery**
   ```bash
   # Download binlogs from verified backup time to now
   aws s3 sync s3://<bucket>/binlogs/ /tmp/binlogs/ --exclude "*" --include "mysql-bin.*"
   
   # Apply binlogs
   mysqlbinlog --start-datetime="<backup-time>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p<pass>
   ```

4. **Verify data integrity**
   - Test critical queries
   - Check row counts
   - Verify recent transactions

## Recovery Targets
- **RTO**: Restore drill ≤ 4 hours
- **RPO**: ≤ 15 minutes (via binlogs)
- **MTTR**: 4-12 hours (to rebuild trust in backups)

## Expected Data Loss
Up to RPO (if incident occurs)

## Affected Components
- Backup artifacts
- Backup metadata
- Backup scripts/configuration
- S3 bucket contents
- Restore procedures

## Assumptions & Prerequisites
- Keep last N verified backups (don't auto-delete)
- Store manifests and checksums with backups
- Automated restore testing in place
- Binlog retention covers backup verification period
- Multiple backup retention tiers (hourly, daily, weekly)

## Verification Steps

1. **Verify backup completeness**
   ```bash
   # Check all required files present
   ls -lh /tmp/backup/
   cat /tmp/backup/xtrabackup_checkpoints
   cat /tmp/backup/xtrabackup_info
   cat /tmp/backup/xtrabackup_binlog_info
   ```

2. **Test backup prepare**
   ```bash
   xtrabackup --prepare --target-dir=/tmp/backup
   # Must complete successfully
   ```

3. **Test restore to temporary instance**
   ```bash
   # Copy back to temporary location
   xtrabackup --copy-back --target-dir=/tmp/backup --datadir=/tmp/test-mysql
   
   # Start MySQL on temporary data
   mysqld --datadir=/tmp/test-mysql --skip-networking
   
   # Run queries to verify data
   mysql -S /tmp/test-mysql/mysql.sock -e "SHOW DATABASES;"
   ```

4. **Verify backup size reasonable**
   ```bash
   # Compare backup size to database size
   du -sh /tmp/backup
   
   # Should be similar to actual DB size
   kubectl exec -n percona <pod> -- du -sh /var/lib/mysql
   ```

## Rollback Procedure
N/A - This is about ensuring backups work, not rolling back a change

## Post-Recovery Actions

1. **Implement automated restore testing**
   ```yaml
   # CronJob to test restores weekly
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: backup-restore-test
   spec:
     schedule: "0 2 * * 0"  # Weekly on Sunday 2 AM
     jobTemplate:
       spec:
         template:
           spec:
             containers:
             - name: restore-tester
               image: percona/percona-xtradb-cluster-operator:latest
               command:
               - /bin/bash
               - -c
               - |
                 # Download latest backup
                 aws s3 sync s3://bucket/backups/latest/ /tmp/test-restore/
                 # Prepare backup
                 xtrabackup --prepare --target-dir=/tmp/test-restore
                 # Verify success
                 if [ $? -eq 0 ]; then
                   echo "✓ Backup restore test PASSED"
                   exit 0
                 else
                   echo "✗ Backup restore test FAILED"
                   exit 1
                 fi
   ```

2. **Add backup verification to backup process**
   - Run xtrabackup --prepare after backup
   - Store checksums with backups
   - Verify checksums before marking backup complete

3. **Enhance monitoring**
   - Alert on backup verification failures
   - Track backup sizes over time
   - Monitor backup duration
   - Alert on missing backup metadata

4. **Improve backup process**
   - Implement backup integrity checks
   - Add pre-backup validation
   - Store backup metadata separately
   - Implement backup versioning

5. **Update procedures**
   - Document backup verification process
   - Schedule monthly full restore drills
   - Keep verified backup list updated
   - Test PITR procedures regularly

6. **Review retention policies**
   - Keep verified backups longer
   - Implement tiered retention (hourly, daily, weekly, monthly)
   - Store backups in multiple regions
   - Consider immutable backups

## Related Scenarios
- S3 backup target unavailable
- Accidental DROP/DELETE/TRUNCATE (when restore needed)
- Widespread data corruption
- Primary DC power/cooling outage

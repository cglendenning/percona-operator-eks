# Application Change Causes Data Corruption Recovery Process

## Primary Recovery Method

1. **Stop further corruption**
   ```bash
   # Set database read-only to prevent further writes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL read_only = ON; SET GLOBAL super_read_only = ON;"
   
   # Stop application deployments and scheduled jobs
   # Disable affected application features if possible
   ```

2. **Identify corruption timeline and scope**
   ```bash
   # Review application logs for errors
   kubectl logs -n <namespace> -l app=<app-name> --tail=1000 | grep -i "error\|corrupt\|invalid"
   
   # Check audit logs for anomalies
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM audit_log WHERE timestamp >= '<suspected-start-date>' ORDER BY timestamp;"
   
   # Run data integrity checks
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "CHECK TABLE <database>.<table>;"
   ```
   - Determine when corruption began (may require forensic analysis of logs)
   - Identify the application version/deployment that introduced the bug
   - Document scope of corruption (which tables/records affected)

3. **Create clean restore environment**
   ```bash
   # Provision separate cluster/namespace for restore
   # Do NOT restore over production!
   # Ensure sufficient storage and compute resources
   ```

4. **Restore database to pre-corruption point**
   ```bash
   # Find backup before corruption began from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<backup-bucket>/backups/ --recursive | grep "<date-before-corruption>"
   
   # Download backup
   kubectl exec -n minio-operator <minio-pod> -- mc cp local/<backup-bucket>/backups/<backup-name>/ /tmp/restore/ --recursive
   
   # Restore to clean environment
   xtrabackup --prepare --target-dir=/tmp/restore
   xtrabackup --copy-back --target-dir=/tmp/restore --datadir=/var/lib/mysql
   ```

5. **Apply PITR using binlogs**
   ```bash
   # Download binlogs from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc cp local/<backup-bucket>/binlogs/ /tmp/binlogs/ --recursive
   
   # Apply binlogs up to BEFORE corruption began
   mysqlbinlog --stop-datetime="<timestamp-before-corruption>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p<pass> -h<restore-host>
   ```

6. **Validate restored data**
   ```bash
   # Run integrity checks
   kubectl exec -n <restore-namespace> <pod> -- mysql -uroot -p<pass> -e "CHECK TABLE <database>.<table>;"
   
   # Verify row counts match expected values
   kubectl exec -n <restore-namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Run application smoke tests on restored environment
   ```

7. **Redeploy fixed application version**
   ```bash
   # Deploy corrected application version
   # Verify application logic fixes the corruption issue
   # Test application functionality with restored data
   ```

8. **Execute cutover**
   ```bash
   # Point applications to restored environment
   # Update DNS/load balancers
   # Restart application pods
   
   # Disable read-only on new primary
   kubectl exec -n <restore-namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;"
   ```

9. **Verify service is restored**
   ```bash
   # Test all critical workflows
   # Monitor error rates
   # Verify data integrity
   # Check application metrics
   ```

## Alternate/Fallback Method

1. **If corruption timeline cannot be determined**
   ```bash
   # Restore from last known good backup (may be days/weeks old)
   # Identify and replay critical transactions selectively from binlogs
   # Use application-level data repair scripts if available
   ```

2. **If selective recovery is required**
   ```bash
   # Identify specific tables/records affected
   # Restore only affected tables to clean state
   # Manually repair or re-import affected data from external sources
   ```

3. **If PITR is not possible**
   ```bash
   # Restore from most recent full backup
   # Apply application-level data correction scripts
   # Manually correct critical data records
   # Document all manual corrections for audit trail
   ```

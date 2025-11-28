# Database Disk Space Exhaustion (Binlog/Undo Log Full) Recovery Process

## Primary Recovery Method

1. **Identify the space issue**
   ```bash
   # Check disk usage on PXC pods
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Check binlog directory size
   kubectl exec -n <namespace> <pod> -- du -sh /var/lib/mysql/binlog*
   
   # Check undo log tablespace size
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT TABLESPACE_NAME, FILE_NAME, ROUND(SUM(FILE_SIZE)/1024/1024/1024, 2) AS SIZE_GB FROM information_schema.FILES WHERE TABLESPACE_NAME LIKE '%undo%' GROUP BY TABLESPACE_NAME;"
   ```

2. **Free space by purging old binlogs**
   ```bash
   # List current binlogs
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW BINARY LOGS;"
   
   # Purge binlogs older than retention period (keep last 7 days as example)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 7 DAY);"
   
   # Or purge to a specific binlog file
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "PURGE BINARY LOGS TO 'mysql-bin.000123';"
   ```

3. **Enable binlog rotation if not already enabled**
   ```bash
   # Check current binlog settings
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'max_binlog_size';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'expire_logs_days';"
   
   # Set max binlog size (default 1GB, can reduce if needed)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL max_binlog_size = 1073741824;"
   
   # Set binlog expiration (days)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL expire_logs_days = 7;"
   ```

4. **Increase PVC size if needed**
   ```bash
   # Check current PVC size
   kubectl get pvc -n <namespace> | grep <pod-name>
   
   # Edit PVC to increase size (if storage class supports expansion)
   kubectl patch pvc -n <namespace> <pvc-name> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>Gi"}}}}'
   
   # Or edit PVC directly
   kubectl edit pvc -n <namespace> <pvc-name>
   # Change: storage: <current-size>Gi to storage: <new-size>Gi
   
   # Wait for PVC expansion to complete
   kubectl get pvc -n <namespace> <pvc-name> -w
   ```

5. **Verify space is freed and writes are restored**
   ```bash
   # Check disk usage again
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Test write operation
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "INSERT INTO <test-table> VALUES (1, 'test');"
   
   # Monitor for any "No space left on device" errors
   kubectl logs -n <namespace> <pod> --tail=100 | grep -i "no space\|disk full"
   ```

## Alternate/Fallback Method

1. **If binlog purge is not sufficient, temporarily disable binlog**
   ```bash
   # WARNING: This will prevent point-in-time recovery until re-enabled
   # Only use if absolutely necessary to restore writes immediately
   
   # Disable binlog temporarily
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL sql_log_bin = OFF;"
   
   # Free space by other means (purge undo logs, temporary tables, etc.)
   # Then re-enable binlog as soon as possible
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL sql_log_bin = ON;"
   ```

2. **Restore from backup after space is freed**
   ```bash
   # Once space is available, ensure backups are working
   # If backups were interrupted due to space, trigger a new backup
   kubectl get perconaxtradbclusterbackup -n <namespace>
   
   # Create a new backup to ensure recovery capability
   kubectl apply -f <backup-cr.yaml>
   ```

## Recovery Targets

- **Restore Time Objective**: 30 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-60 minutes

## Expected Data Loss

None if caught early; potential loss if writes were blocked

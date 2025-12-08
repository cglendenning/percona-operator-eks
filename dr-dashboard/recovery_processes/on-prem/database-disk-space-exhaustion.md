# Database Disk Space Exhaustion (Data Directory) Recovery Process

This scenario covers persistent storage exhaustion in the MySQL data directory, including binlogs, undo logs, redo logs, and InnoDB tablespaces. This is distinct from temporary tablespace exhaustion, which is covered in a separate scenario.

## Primary Recovery Method

1. **Identify what's consuming persistent storage**
   ```bash
   # Check overall disk usage on PXC pods
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Check what's consuming space in MySQL data directory
   kubectl exec -n <namespace> <pod> -- du -sh /var/lib/mysql/* | sort -h
   
   # Check binlog directory size (often the culprit)
   kubectl exec -n <namespace> <pod> -- du -sh /var/lib/mysql/binlog*
   kubectl exec -n <namespace> <pod> -- ls -lh /var/lib/mysql/ | grep mysql-bin
   
   # Check undo log tablespace size (grows with long transactions)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT TABLESPACE_NAME, FILE_NAME, 
            ROUND(SUM(FILE_SIZE)/1024/1024/1024, 2) AS SIZE_GB 
     FROM information_schema.FILES 
     WHERE TABLESPACE_NAME LIKE '%undo%' 
     GROUP BY TABLESPACE_NAME, FILE_NAME;"
   
   # Check data file sizes by schema
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT table_schema, 
            ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS size_gb 
     FROM information_schema.tables 
     GROUP BY table_schema 
     ORDER BY size_gb DESC;"
   
   # Check for long-running transactions (cause undo log growth)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT trx_id, trx_state, trx_started, 
            TIMESTAMPDIFF(SECOND, trx_started, NOW()) as age_seconds,
            trx_rows_locked, trx_rows_modified
     FROM information_schema.INNODB_TRX 
     ORDER BY trx_started;"
   ```

2. **Free space by purging binlogs**
   ```bash
   # List current binlogs and their sizes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW BINARY LOGS;"
   
   # Check which binlog is currently in use by replication
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW MASTER STATUS;"
   
   # Purge binlogs older than retention period
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 3 DAY);"
   
   # Or purge to a specific binlog file (safer)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     PURGE BINARY LOGS TO 'mysql-bin.000123';"
   ```

3. **Address undo log growth**
   ```bash
   # If undo logs are large, find and kill long-running transactions
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT ID, USER, HOST, DB, TIME, STATE, 
            SUBSTRING(INFO, 1, 100) as query_preview
     FROM information_schema.PROCESSLIST 
     WHERE COMMAND != 'Sleep' AND TIME > 600 
     ORDER BY TIME DESC;"
   
   # Kill specific long-running transaction (use with caution)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "KILL <thread_id>;"
   
   # Monitor undo log purge progress
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SHOW ENGINE INNODB STATUS\G" | grep -A5 "TRANSACTIONS"
   ```

4. **Configure binlog retention to prevent recurrence**
   ```bash
   # Check current binlog settings
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SHOW VARIABLES LIKE 'binlog_expire_logs_seconds';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SHOW VARIABLES LIKE 'max_binlog_size';"
   
   # Set binlog expiration (604800 seconds = 7 days)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SET GLOBAL binlog_expire_logs_seconds = 604800;"
   
   # Note: For permanent change, update PerconaXtraDBCluster CR configuration
   ```

5. **Expand PVC if needed**
   ```bash
   # Check current PVC size and usage
   kubectl get pvc -n <namespace> -l app.kubernetes.io/component=pxc
   
   # Expand PVC (if storage class supports it)
   kubectl patch pvc -n <namespace> <pvc-name> \
     -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
   
   # Wait for expansion to complete
   kubectl get pvc -n <namespace> <pvc-name> -w
   ```

6. **Verify recovery**
   ```bash
   # Check disk usage
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Test write capability
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     CREATE TABLE IF NOT EXISTS test.disk_test (id INT);
     INSERT INTO test.disk_test VALUES (1);
     DROP TABLE test.disk_test;"
   
   # Check for errors
   kubectl logs -n <namespace> <pod> --tail=50 | grep -i "no space\|disk full"
   ```

## Alternate/Fallback Method

1. **Emergency: Temporarily disable binlogging**
   ```bash
   # WARNING: This prevents point-in-time recovery until re-enabled
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SET GLOBAL sql_log_bin = OFF;"
   
   # Free space, then immediately re-enable
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SET GLOBAL sql_log_bin = ON;"
   ```

2. **Truncate logs consuming space**
   ```bash
   # Truncate slow query log
   kubectl exec -n <namespace> <pod> -- truncate -s 0 /var/lib/mysql/slow-query.log
   
   # Truncate general log (if enabled)
   kubectl exec -n <namespace> <pod> -- truncate -s 0 /var/lib/mysql/general.log
   ```

## Recovery Targets

- **Restore Time Objective**: 30 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-60 minutes

## Expected Data Loss

None if caught early; potential loss if writes were blocked

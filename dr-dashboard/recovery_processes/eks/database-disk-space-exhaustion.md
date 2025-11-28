# Database Disk Space Exhaustion Recovery Process

## Primary Recovery Method

1. **Identify what's using disk space**
   ```bash
   # Check overall disk usage on PXC pods
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Check what's consuming space in MySQL data directory
   kubectl exec -n <namespace> <pod> -- du -sh /var/lib/mysql/* | sort -h
   
   # Check binlog directory size
   kubectl exec -n <namespace> <pod> -- du -sh /var/lib/mysql/binlog*
   
   # Check undo log tablespace size
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT TABLESPACE_NAME, FILE_NAME, ROUND(SUM(FILE_SIZE)/1024/1024/1024, 2) AS SIZE_GB FROM information_schema.FILES WHERE TABLESPACE_NAME LIKE '%undo%' GROUP BY TABLESPACE_NAME;"
   
   # Check data file sizes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT table_schema, ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS size_gb FROM information_schema.tables GROUP BY table_schema ORDER BY size_gb DESC;"
   
   # Check log file sizes (slow query log, general log, error log)
   kubectl exec -n <namespace> <pod> -- ls -lh /var/lib/mysql/*.log 2>/dev/null
   kubectl exec -n <namespace> <pod> -- ls -lh /var/log/mysql/*.log 2>/dev/null
   
   # Check temporary table space
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'tmpdir';"
   kubectl exec -n <namespace> <pod> -- du -sh $(mysql -uroot -p<pass> -e "SELECT @@tmpdir;" -s -N)
   
   # Check EBS volume usage via CloudWatch
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EBS \
     --metric-name VolumeUsedPercent \
     --dimensions Name=VolumeId,Value=<volume-id> \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Average,Maximum
   ```

2. **Free space by purging old files/logs**
   ```bash
   # If binlogs are the issue:
   # List current binlogs
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW BINARY LOGS;"
   
   # Purge binlogs older than retention period (keep last 7 days as example)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 7 DAY);"
   
   # Or purge to a specific binlog file
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "PURGE BINARY LOGS TO 'mysql-bin.000123';"
   
   # If slow query log or general log are the issue:
   # Rotate or truncate log files
   kubectl exec -n <namespace> <pod> -- truncate -s 0 /var/lib/mysql/slow-query.log
   kubectl exec -n <namespace> <pod> -- truncate -s 0 /var/lib/mysql/general.log
   
   # If temporary tables are the issue:
   # Kill long-running queries that might be creating large temp tables
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' AND TIME > 300 ORDER BY TIME DESC;"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "KILL <query-id>;"
   
   # If undo logs are the issue:
   # Check for long-running transactions
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM information_schema.INNODB_TRX ORDER BY trx_started;"
   # Kill long-running transactions if safe
   ```

3. **Enable log rotation if not already enabled**
   ```bash
   # Check current binlog settings
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'max_binlog_size';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'expire_logs_days';"
   
   # Set max binlog size (default 1GB, can reduce if needed)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL max_binlog_size = 1073741824;"
   
   # Set binlog expiration (days)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL expire_logs_days = 7;"
   
   # Configure slow query log rotation
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL slow_query_log_rotation_size = 1073741824;"
   ```

4. **Increase EBS volume size if needed**
   ```bash
   # Get EBS volume ID from PVC
   kubectl get pvc -n <namespace> <pvc-name> -o jsonpath='{.spec.volumeName}'
   aws ec2 describe-volumes --volume-ids <volume-id>
   
   # Modify EBS volume size
   aws ec2 modify-volume --volume-id <volume-id> --size <new-size-gb>
   
   # Wait for modification to complete
   aws ec2 describe-volumes-modifications --volume-ids <volume-id>
   
   # Resize filesystem inside pod
   kubectl exec -n <namespace> <pod> -- resize2fs /dev/<device>
   
   # Or if using ext4, check and resize
   kubectl exec -n <namespace> <pod> -- df -h
   kubectl exec -n <namespace> <pod> -- growpart /dev/<device> 1
   kubectl exec -n <namespace> <pod> -- resize2fs /dev/<device>1
   ```

5. **Verify space is freed and writes are restored**
   ```bash
   # Check disk usage again
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Test write operation
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "INSERT INTO <test-table> VALUES (1, 'test');"
   
   # Monitor for any "No space left on device" errors
   kubectl logs -n <namespace> <pod> --tail=100 | grep -i "no space\|disk full"
   
   # Verify MySQL can write to all necessary locations
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'datadir';"
   kubectl exec -n <namespace> <pod> -- touch /var/lib/mysql/test-write && rm /var/lib/mysql/test-write
   ```

## Alternate/Fallback Method

1. **Temporarily disable non-critical logging**
   ```bash
   # WARNING: This will reduce observability until re-enabled
   # Only use if absolutely necessary to restore writes immediately
   
   # Disable slow query log if it's consuming space
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL slow_query_log = OFF;"
   
   # Disable general log if it's consuming space
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL general_log = OFF;"
   
   # Disable binlog temporarily (WARNING: prevents point-in-time recovery)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL sql_log_bin = OFF;"
   
   # Free space by other means (purge undo logs, temporary tables, etc.)
   # Then re-enable logging as soon as possible
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL sql_log_bin = ON;"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL slow_query_log = ON;"
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

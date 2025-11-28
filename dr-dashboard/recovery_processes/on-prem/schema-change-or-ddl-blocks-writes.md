# Schema Change or DDL Blocks Writes Recovery Process

## Primary Recovery Method

1. **Identify the blocking DDL operation**
   ```bash
   # Check for running DDL processes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW PROCESSLIST;" | grep -i "alter\|create\|drop\|rename"
   
   # Check for metadata locks
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM performance_schema.metadata_locks WHERE OBJECT_TYPE='TABLE';"
   
   # Check for blocked queries
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM information_schema.processlist WHERE State LIKE '%metadata%' OR State LIKE '%Waiting%';"
   ```

2. **Assess DDL progress and remaining time**
   ```bash
   # Check DDL progress (if using online DDL)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM information_schema.innodb_online_ddl_log;"
   
   # Estimate remaining time based on table size and operation type
   # If DDL is >90% complete, consider waiting
   # If DDL just started and will take hours, consider killing it
   ```

3. **Decision: Wait, Kill, or Rollback**
   
   **Option A: Wait if DDL is near completion**
   ```bash
   # Monitor progress
   watch -n 5 'kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW PROCESSLIST;" | grep -i "alter\|create"'
   
   # Continue monitoring until DDL completes
   ```

   **Option B: Kill DDL if safe and early in process**
   ```bash
   # Identify DDL process ID
   DDL_PID=$(kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT ID FROM information_schema.processlist WHERE Command='Query' AND Info LIKE '%ALTER%' OR Info LIKE '%CREATE%';" | tail -1)
   
   # Kill the process
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "KILL $DDL_PID;"
   
   # Verify writes are unblocked
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM information_schema.processlist WHERE State LIKE '%metadata%';"
   ```

   **Option C: Rollback DDL if possible**
   ```bash
   # If DDL was ALTER TABLE, check if it can be rolled back
   # For some operations, you may need to reverse the change
   # Example: If ALTER TABLE ADD COLUMN, then ALTER TABLE DROP COLUMN
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "ALTER TABLE <table> DROP COLUMN <column>;"  # Only if safe!
   ```

4. **Verify writes are restored**
   ```bash
   # Test write operation
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "INSERT INTO <test_table> VALUES (1, 'test');"
   
   # Check application can write
   # Monitor application logs for successful writes
   ```

5. **Monitor for any schema inconsistencies**
   ```bash
   # Check table structure
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW CREATE TABLE <table>;"
   
   # Verify table integrity
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "CHECK TABLE <table>;"
   ```

## Alternate/Fallback Method

1. **If DDL cannot be killed safely**
   ```bash
   # Failover to replica (if available and not affected by DDL)
   # Check replica status
   kubectl exec -n <namespace> <replica-pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G"
   
   # If replica is healthy and not running DDL, promote it
   # Update application connections to point to replica
   ```

2. **If DDL corrupted schema**
   ```bash
   # Restore from backup
   # Find backup before DDL started
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<backup-bucket>/backups/ --recursive | grep "<date-before-ddl>"
   
   # Restore schema only (not data if data is still good)
   # Or restore full backup if data corruption occurred
   ```

3. **If replica failover not possible**
   ```bash
   # Wait for DDL to complete (may take hours)
   # Put application in read-only mode
   # Notify users of extended maintenance window
   # Monitor DDL progress continuously
   ```

## Recovery Targets

- **Restore Time Objective**: 30 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 15-60 minutes

## Expected Data Loss

None if handled correctly; potential data loss if DDL is killed mid-operation

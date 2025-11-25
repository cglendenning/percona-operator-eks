# Both DCs Up But Replication Stops (Broken Channel) Recovery Process

## Scenario
Both DCs up but replication stops (broken channel)

## Detection Signals
- Seconds_Behind_Master increasing continuously
- Replication IO thread stopped
- Replication SQL thread stopped
- Monitoring alerts for replication lag
- Error logs showing replication failures

## Primary Recovery Method
Fix replication (purge relay logs; CHANGE MASTER to correct coordinates; GTID resync)

### Steps

1. **Identify the replication problem**
   ```bash
   # On secondary DC
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G"
   ```
   
   Look for:
   - `Slave_IO_Running: No`
   - `Slave_SQL_Running: No`
   - `Last_IO_Error` or `Last_SQL_Error` messages

2. **Check binlog position on primary**
   ```bash
   kubectl --context=primary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW MASTER STATUS\G"
   ```

3. **Stop slave on secondary**
   ```bash
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "STOP SLAVE;"
   ```

4. **Check for common issues**
   
   **Network connectivity:**
   ```bash
   kubectl exec -n percona <pod> -- ping <primary-dc-endpoint>
   ```
   
   **Binlog retention:**
   ```bash
   kubectl --context=primary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW BINARY LOGS;"
   ```

5. **Reset and restart replication**
   
   **Option A: Using GTID (if enabled):**
   ```bash
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> << 'EOF'
   STOP SLAVE;
   SET GLOBAL gtid_purged='<gtid-from-primary>';
   CHANGE MASTER TO
     MASTER_HOST='<primary-host>',
     MASTER_USER='replication',
     MASTER_PASSWORD='<repl-password>',
     MASTER_AUTO_POSITION=1;
   START SLAVE;
   EOF
   ```
   
   **Option B: Using binlog coordinates:**
   ```bash
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> << 'EOF'
   STOP SLAVE;
   CHANGE MASTER TO
     MASTER_HOST='<primary-host>',
     MASTER_USER='replication',
     MASTER_PASSWORD='<repl-password>',
     MASTER_LOG_FILE='<binlog-file>',
     MASTER_LOG_POS=<position>;
   START SLAVE;
   EOF
   ```

6. **Verify replication resumed**
   ```bash
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
   ```

7. **Monitor catch-up progress**
   ```bash
   watch -n 5 "kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind_Master"
   ```

## Alternate/Fallback Method
If diverged, rebuild replica from S3 backup + binlogs

### Steps

1. **If replication is too far behind or corrupted**
   - Secondary has diverged (errant transactions)
   - Binlogs purged on primary
   - Data corruption on secondary

2. **Stop secondary cluster (maintenance mode)**
   ```bash
   kubectl scale statefulset <sts> -n percona --replicas=0
   ```

3. **Restore from backup**
   ```bash
   # Get latest backup from S3
   aws s3 ls s3://<backup-bucket>/backups/ --recursive | sort | tail -1
   
   # Download and restore
   xtrabackup --copy-back --target-dir=<backup-path>
   ```

4. **Start secondary cluster**
   ```bash
   kubectl scale statefulset <sts> -n percona --replicas=3
   ```

5. **Set up replication from restore point**
   ```bash
   # Use binlog coordinates from backup metadata
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> << 'EOF'
   CHANGE MASTER TO
     MASTER_HOST='<primary-host>',
     MASTER_USER='replication',
     MASTER_PASSWORD='<repl-password>',
     MASTER_LOG_FILE='<binlog-from-backup>',
     MASTER_LOG_POS=<position-from-backup>;
   START SLAVE;
   EOF
   ```

## Recovery Targets
- **RTO**: 15-60 minutes
- **RPO**: 0 (no failover)
- **MTTR**: 30-120 minutes

## Expected Data Loss
None (still primary)

## Affected Components
- MySQL replication channel
- Binary logs
- Network between DCs
- Replication user credentials

## Assumptions & Prerequisites
- Binlog retention ≥ rebuild time
- Network connectivity between DCs
- Replication credentials valid
- Monitoring for errant transactions configured
- GTID enabled (recommended) or binlog coordinates known

## Verification Steps

1. **Replication status healthy**
   ```bash
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G" | grep -A 5 "Slave_IO_Running"
   ```
   
   Should show:
   - `Slave_IO_Running: Yes`
   - `Slave_SQL_Running: Yes`
   - `Seconds_Behind_Master: 0` (or decreasing)

2. **No errors in replication**
   ```bash
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G" | grep -i error
   ```

3. **Test data flow**
   ```bash
   # On primary
   kubectl --context=primary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE DATABASE IF NOT EXISTS repl_test; USE repl_test; CREATE TABLE IF NOT EXISTS test (id INT, ts TIMESTAMP); INSERT INTO test VALUES (1, NOW());"
   
   # Wait a few seconds, then on secondary
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM repl_test.test;"
   ```

4. **Check for errant transactions**
   ```bash
   # Compare GTID sets
   kubectl --context=primary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT @@gtid_executed;"
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT @@gtid_executed;"
   ```

## Rollback Procedure
If replication fix causes issues:
1. Stop slave again
2. Revert to backup/restore method
3. Assess data consistency carefully

## Post-Recovery Actions

1. **Root cause analysis**
   - Why did replication break?
   - Network issue? Credentials? Configuration?

2. **Improve monitoring**
   - Alert on Seconds_Behind_Master > 60s
   - Alert on IO/SQL thread stopped
   - Monitor errant transactions

3. **Review binlog retention**
   - Ensure retention covers typical outage windows
   - Consider increasing retention period

4. **Test replication failover**
   - Schedule regular replication failover drills
   - Document actual RTO/RPO

5. **Harden replication**
   - Review replication user permissions
   - Consider semi-synchronous replication
   - Implement GTID if not already using

## Related Scenarios
- Primary DC network partition
- Primary DC power/cooling outage
- Credential compromise
- Both DCs down (different scenario)

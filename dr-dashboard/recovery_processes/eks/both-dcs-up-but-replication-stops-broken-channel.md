# Both DCs Up But Replication Stops (Broken Channel) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
```





## Primary Recovery Method
Fix replication (purge relay logs; CHANGE MASTER to correct coordinates; GTID resync)

### Steps

1. **Identify the replication problem**
   ```bash
   # On secondary DC
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G"
   ```
   
   Look for:
   - `Slave_IO_Running: No`
   - `Slave_SQL_Running: No`
   - `Last_IO_Error` or `Last_SQL_Error` messages

2. **Check binlog position on primary**
   ```bash
   kubectl --context=primary-dc exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW MASTER STATUS\G"
   ```

3. **Stop slave on secondary**
   ```bash
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "STOP SLAVE;"
   ```

4. **Check for common issues**
   
   **Network connectivity:**
   ```bash
   kubectl exec -n percona ${POD_NAME} -- ping <primary-dc-endpoint>
   ```
   
   **Binlog retention:**
   ```bash
   kubectl --context=primary-dc exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW BINARY LOGS;"
   ```

5. **Reset and restart replication**
   
   **Option A: Using GTID (if enabled):**
   ```bash
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} << 'EOF'
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
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} << 'EOF'
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

6. **Verify service is restored**
   ```bash
   # Verify replication resumed
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
   
   # Monitor catch-up progress
   watch -n 5 "kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind_Master"
   
   # Test data flow
   kubectl --context=primary-dc exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS repl_test; USE repl_test; CREATE TABLE IF NOT EXISTS test (id INT, ts TIMESTAMP); INSERT INTO test VALUES (1, NOW());"
   
   # Wait a few seconds, then verify on secondary
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT * FROM repl_test.test;"
   ```

## Alternate/Fallback Method
If diverged, rebuild replica from S3 backup + binlogs

### Steps

1. **Stop secondary cluster (maintenance mode)**
   ```bash
   kubectl scale statefulset <sts> -n percona --replicas=0
   ```

2. **Restore from backup**
   ```bash
   # Get latest backup from S3
   aws s3 ls s3://<backup-bucket>/backups/ --recursive | sort | tail -1
   
   # Download and restore
   aws s3 sync s3://<backup-bucket>/backups/<backup-name>/ /tmp/restore/ --delete
   xtrabackup --prepare --target-dir=/tmp/restore
   xtrabackup --copy-back --target-dir=/tmp/restore --datadir=/var/lib/mysql
   ```

3. **Start secondary cluster**
   ```bash
   kubectl scale statefulset <sts> -n percona --replicas=3
   ```

4. **Set up replication from restore point**
   ```bash
   # Use binlog coordinates from backup metadata
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} << 'EOF'
   CHANGE MASTER TO
     MASTER_HOST='<primary-host>',
     MASTER_USER='replication',
     MASTER_PASSWORD='<repl-password>',
     MASTER_LOG_FILE='<binlog-from-backup>',
     MASTER_LOG_POS=<position-from-backup>;
   START SLAVE;
   EOF
   ```

5. **Verify service is restored**
   ```bash
   # Verify replication is working
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running"
   
   # Test data flow
   kubectl --context=primary-dc exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "INSERT INTO repl_test.test VALUES (2, NOW());"
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT * FROM repl_test.test;"
   ```

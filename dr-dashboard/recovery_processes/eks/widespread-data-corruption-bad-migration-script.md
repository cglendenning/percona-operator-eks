# Widespread Data Corruption (Bad Migration/Script) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
```





## Primary Recovery Method
PITR to pre-change timestamp on clean environment; validate; cutover

### Steps

⚠️ **CRITICAL**: Do NOT make further changes until recovery plan confirmed!

1. **Stop all changes immediately**
   ```bash
   # Set database read-only
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = ON; SET GLOBAL super_read_only = ON;"
   
   # Stop automated jobs, deployments, scheduled tasks
   ```

2. **Identify the corruption source and timestamp**
   - Review deployment logs
   - Check Git history for recent migrations
   - Find exact time BEFORE corruption occurred
   - Document the bad change for rollback

3. **Create clean restore environment**
   - Provision separate cluster/namespace
   - Do NOT restore over production!
   - Ensure sufficient resources

4. **Restore backup to pre-corruption time**
   ```bash
   # Find backup before the bad change
   aws s3 ls s3://<backup-bucket>/backups/ --recursive | grep "<date-before-corruption>"
   
   # Download backup
   aws s3 sync s3://<backup-bucket>/backups/<backup-name>/ /tmp/restore/ --delete
   
   # Restore to clean environment
   xtrabackup --prepare --target-dir=/tmp/restore
   xtrabackup --copy-back --target-dir=/tmp/restore --datadir=/var/lib/mysql
   ```

5. **Apply PITR using binlogs**
   ```bash
   # Download binlogs from S3
   aws s3 sync s3://<backup-bucket>/binlogs/ /tmp/binlogs/ --exclude "*" --include "mysql-bin.*"
   
   # Apply binlogs up to BEFORE corruption
   mysqlbinlog --stop-datetime="<timestamp-before-corruption>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h<restore-host>
   ```

6. **Validate restored data**
   ```bash
   # Run integrity checks
   mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h<restore-host> -e "CHECK TABLE <database>.<table>;"
   
   # Verify row counts
   mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h<restore-host> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Run application smoke tests on restored environment
   ```

7. **Execute cutover**
   ```bash
   # Point applications to restored environment
   # Update DNS/load balancers
   # Restart application pods
   
   # Disable read-only on new primary
   kubectl exec -n <new-namespace> ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;"
   ```

8. **Verify service is restored**
   ```bash
   # Test all critical workflows
   # Monitor error rates
   # Verify data integrity
   # Check application metrics
   ```

## Alternate/Fallback Method
If change is reversible, apply compensating migration from audit trail

### Steps

1. **Analyze the bad change**
   - Review migration script
   - Determine if it's reversible (e.g., ALTER TABLE can be reverted)

2. **Write compensating migration**
   ```sql
   -- Example: If bad change was ALTER TABLE users DROP COLUMN email;
   -- Compensating change (if email data still exists elsewhere):
   ALTER TABLE users ADD COLUMN email VARCHAR(255);
   UPDATE users SET email = (SELECT email FROM users_backup WHERE users_backup.id = users.id);
   ```

3. **Test on replica first**
   ```bash
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} < compensating-migration.sql
   ```

4. **Apply to production if test succeeds**
   ```bash
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} < compensating-migration.sql
   ```

5. **Verify service is restored**
   ```bash
   # Verify data integrity
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CHECK TABLE <database>.<table>;"
   
   # Test write operations from application
   ```

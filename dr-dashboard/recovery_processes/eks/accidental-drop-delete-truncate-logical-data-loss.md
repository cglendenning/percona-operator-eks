# Accidental DROP/DELETE/TRUNCATE (Logical Data Loss) Recovery Process

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
read -p "Enter backup pod name: " BACKUP_POD
```





## Primary Recovery Method
Point-in-time restore from S3 backup + binlogs to side instance; recover affected tables via mysqlpump/mydumper

### Steps

⚠️ **CRITICAL**: Do NOT make further changes to the production database until recovery plan is confirmed!

1. **Stop the bleeding**
   ```bash
   # Immediately put database in read-only mode to prevent further changes
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = ON;"
   
   # Alert all teams to stop operations
   # Prevent automated jobs from running
   ```

2. **Identify the exact timestamp of data loss**
   ```bash
   # Check audit logs, application logs, or binlogs
   # Find the exact time BEFORE the destructive operation
   
   # Example: Check binlogs
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysqlbinlog /var/lib/mysql/mysql-bin.000123 | grep -i "DROP\|DELETE\|TRUNCATE"
   ```

3. **Locate the most recent backup before the incident**
   ```bash
   # List available backups
   aws s3 ls s3://<backup-bucket>/backups/ --recursive
   
   # Or use Percona Backup tool
   kubectl exec -n ${NAMESPACE} ${BACKUP_POD} -- pbm list
   ```

4. **Restore backup to a SIDE INSTANCE (not production!)**
   ```bash
   # Create a temporary restore environment
   # Download backup from S3
   aws s3 sync s3://<backup-bucket>/backups/<backup-name>/ /tmp/restore/
   
   # Prepare backup
   xtrabackup --prepare --target-dir=/tmp/restore
   
   # Copy back to temporary MySQL instance
   xtrabackup --copy-back --target-dir=/tmp/restore --datadir=/tmp/restore-mysql
   ```

5. **Apply point-in-time recovery using binlogs**
   ```bash
   # Download binlogs from S3
   aws s3 sync s3://<backup-bucket>/binlogs/ /tmp/binlogs/ --exclude "*" --include "mysql-bin.*"
   
   # Apply binlogs up to BEFORE the destructive operation
   mysqlbinlog --stop-datetime="<timestamp-before-loss>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h<restore-host>
   ```

6. **Extract affected tables/data**
   ```bash
   # Use mysqldump or mydumper to extract only the affected tables
   mysqldump -uroot -p${MYSQL_ROOT_PASSWORD} -h<restore-host> <database> <table> > restored_table.sql
   
   # Or use mydumper for parallel extraction
   mydumper -u root -p ${MYSQL_ROOT_PASSWORD} -h <restore-host> -B <database> -T <table> -o /tmp/restored_data
   ```

7. **Restore to production**
   ```bash
   # Import the restored table/data
   mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h<production-host> <database> < restored_table.sql
   
   # Or using mydumper output
   myloader -u root -p ${MYSQL_ROOT_PASSWORD} -h <production-host> -d /tmp/restored_data
   ```

8. **Verify service is restored**
   ```bash
   # Verify data is restored
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Re-enable writes
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL read_only = OFF;"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
If using Percona Backup for MySQL (PBM physical), do tablespace-level restore where possible

### Steps

1. **Restore specific tablespaces from PBM backup**
   ```bash
   # Use PBM to restore specific tablespaces
   kubectl exec -n ${NAMESPACE} ${BACKUP_POD} -- pbm restore --backup=<backup-name> --tablespaces=<database>.<table>
   ```

2. **Import tablespaces**
   ```bash
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e \
     "ALTER TABLE <database>.<table> IMPORT TABLESPACE;"
   ```

3. **Verify service is restored**
   ```bash
   # Verify data is restored
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Test write operations from application
   ```

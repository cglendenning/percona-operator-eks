# Accidental DROP/DELETE/TRUNCATE (Logical Data Loss) Recovery Process

## Primary Recovery Method
Point-in-time restore from MinIO backup + binlogs to side instance; recover affected tables via mysqlpump/mydumper

### Steps

⚠️ **CRITICAL**: Do NOT make further changes to the production database until recovery plan is confirmed!

1. **Stop the bleeding**
   ```bash
   # Immediately put database in read-only mode
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SET GLOBAL read_only = ON;"
   ```

2. **Identify the exact timestamp of data loss**
   ```bash
   # Check audit logs, application logs, or binlogs
   # Find the exact time BEFORE the destructive operation
   ```

3. **Locate the most recent backup before the incident**
   ```bash
   # List available backups from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<backup-bucket>/backups/ --recursive
   ```

4. **Restore backup to a SIDE INSTANCE (not production!)**
   ```bash
   # Create a temporary restore environment
   # Download backup from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc cp local/<backup-bucket>/backups/<backup-name>/ /tmp/restore/ --recursive
   
   # Prepare backup
   xtrabackup --prepare --target-dir=/tmp/restore
   
   # Copy back to temporary MySQL instance
   xtrabackup --copy-back --target-dir=/tmp/restore --datadir=/tmp/restore-mysql
   ```

5. **Apply point-in-time recovery using binlogs**
   ```bash
   # Download binlogs from MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc cp local/<backup-bucket>/binlogs/ /tmp/binlogs/ --recursive
   
   # Apply binlogs up to BEFORE the destructive operation
   mysqlbinlog --stop-datetime="<timestamp-before-loss>" /tmp/binlogs/mysql-bin.* | mysql -uroot -p<password> -h<restore-host>
   ```

6. **Extract affected tables/data**
   ```bash
   # Use mysqldump or mydumper to extract only the affected tables
   mysqldump -uroot -p<password> -h<restore-host> <database> <table> > restored_table.sql
   
   # Or use mydumper for parallel extraction
   mydumper -u root -p <password> -h <restore-host> -B <database> -T <table> -o /tmp/restored_data
   ```

7. **Restore to production**
   ```bash
   # Import the restored table/data
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> <database> < restored_table.sql
   
   # Or using mydumper output
   myloader -u root -p <password> -h <production-host> -d /tmp/restored_data
   ```

8. **Verify service is restored**
   ```bash
   # Verify data is restored
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Re-enable writes
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SET GLOBAL read_only = OFF;"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
If using Percona Backup for MySQL (PBM physical), do tablespace-level restore where possible

### Steps

1. **Restore specific tablespaces from PBM backup**
   ```bash
   # Use PBM to restore specific tablespaces
   kubectl exec -n <namespace> <backup-pod> -- pbm restore --backup=<backup-name> --tablespaces=<database>.<table>
   ```

2. **Import tablespaces**
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e \
     "ALTER TABLE <database>.<table> IMPORT TABLESPACE;"
   ```

3. **Verify service is restored**
   ```bash
   # Verify data is restored
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Test write operations from application
   ```

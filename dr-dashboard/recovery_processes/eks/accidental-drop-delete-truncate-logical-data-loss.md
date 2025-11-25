# Accidental DROP/DELETE/TRUNCATE (Logical Data Loss) Recovery Process

## Scenario
Accidental DROP/DELETE/TRUNCATE (logical data loss)

## Detection Signals
- Application errors (missing data, constraint violations)
- Missing rows or tables
- Audit logs showing unexpected DROP/DELETE/TRUNCATE
- Sudden database or table size drops
- User reports of missing data
- Monitoring alerts on table/row counts

## Primary Recovery Method
Point-in-time restore from S3 backup + binlogs to side instance; recover affected tables via mysqlpump/mydumper

### Steps

⚠️ **CRITICAL**: Do NOT make further changes to the production database until recovery plan is confirmed!

1. **Stop the bleeding**
   ```bash
   # Immediately put database in read-only mode to prevent further changes
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SET GLOBAL read_only = ON;"
   
   # Alert all teams to stop operations
   # Prevent automated jobs from running
   ```

2. **Identify the exact timestamp of data loss**
   ```bash
   # Check audit logs, application logs, or binlogs
   # Find the exact time BEFORE the destructive operation
   
   # Example: Check binlogs
   kubectl exec -n <namespace> <pod-name> -- mysqlbinlog /var/lib/mysql/mysql-bin.000123 | grep -i "DROP\|DELETE\|TRUNCATE"
   ```

3. **Locate the most recent backup before the incident**
   ```bash
   # List available backups
   aws s3 ls s3://<backup-bucket>/backups/ --recursive
   
   # Or use Percona Backup tool
   kubectl exec -n <namespace> <backup-pod> -- pbm list
   ```

4. **Restore backup to a SIDE INSTANCE (not production!)**
   ```bash
   # Create a temporary restore environment
   # Use a separate namespace or cluster
   
   # Restore from S3
   xtrabackup --copy-back --target-dir=/path/to/backup
   
   # Start MySQL on side instance
   # Apply binlogs up to the point BEFORE the data loss
   mysqlbinlog --stop-datetime="2024-01-15 14:30:00" /path/to/binlogs/* | mysql -uroot -p
   ```

5. **Verify data exists on side instance**
   ```bash
   # Connect to side instance
   mysql -h <side-instance> -uroot -p
   
   # Verify affected tables/rows exist
   USE <database>;
   SELECT COUNT(*) FROM <affected_table>;
   SELECT * FROM <affected_table> WHERE <conditions> LIMIT 10;
   ```

6. **Export the recovered data**
   ```bash
   # Use mydumper for large tables
   mydumper --host=<side-instance> --user=root --password=<pass> \
     --database=<database> --tables-list=<table> \
     --outputdir=/tmp/recovery
   
   # Or use mysqldump for smaller datasets
   mysqldump -h <side-instance> -uroot -p<pass> <database> <table> > recovered_data.sql
   ```

7. **Prepare production for data import**
   ```bash
   # If table was dropped, recreate it (get DDL from side instance)
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW CREATE TABLE <database>.<table>;"
   
   # If needed, create the table structure
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> <database> < create_table.sql
   ```

8. **Import recovered data to production**
   ```bash
   # Load data using myloader
   myloader --host=<prod-host> --user=root --password=<pass> \
     --database=<database> --directory=/tmp/recovery \
     --overwrite-tables
   
   # Or use mysql command
   kubectl exec -i -n <namespace> <pod-name> -- mysql -uroot -p<password> <database> < recovered_data.sql
   ```

9. **Verify data integrity**
   ```bash
   # Check row counts match
   # Verify sample data
   # Run application smoke tests
   # Check referential integrity
   ```

10. **Re-enable writes**
    ```bash
    kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SET GLOBAL read_only = OFF;"
    ```

## Alternate/Fallback Method
If using Percona Backup for MySQL (PBM physical), do tablespace-level restore where possible

### Steps
1. **Use PBM for tablespace restore**
   ```bash
   # List available backups
   kubectl exec -n <namespace> <backup-pod> -- pbm list
   
   # Restore specific tablespace
   kubectl exec -n <namespace> <backup-pod> -- pbm restore --time="2024-01-15T14:30:00Z" \
     --database=<database> --table=<table>
   ```

2. **Import tablespace into production**
   ```bash
   # Discard current tablespace
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e \
     "ALTER TABLE <database>.<table> DISCARD TABLESPACE;"
   
   # Copy restored .ibd file
   kubectl cp <backup-pod>:/restore/<table>.ibd <prod-pod>:/var/lib/mysql/<database>/<table>.ibd
   
   # Import tablespace
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e \
     "ALTER TABLE <database>.<table> IMPORT TABLESPACE;"
   ```

## Recovery Targets
- **RTO**: 1-4 hours (depends on dataset size)
- **RPO**: ≤ 5 minutes
- **MTTR**: 2-8 hours

## Expected Data Loss
Up to RPO (5-15 minutes typical)

## Affected Components
- Data layer (specific tables/databases)
- Backups
- Binary logs
- Application data access layer

## Assumptions & Prerequisites
- Frequent binlog backups to S3
- Tested PITR (Point-In-Time Recovery) runbooks
- Separate restore host/environment available
- Sufficient storage for side instance restore
- Backup retention covers the incident timeframe
- Binlog retention >= MTTR

## Verification Steps
1. **Data completeness check**
   ```bash
   # Compare row counts
   # Before (from side instance):
   mysql -h <side-instance> -uroot -p -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # After (from production):
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SELECT COUNT(*) FROM <database>.<table>;"
   ```

2. **Data integrity check**
   ```bash
   # Run checksums on sample data
   # Verify primary keys and foreign keys
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e \
     "CHECK TABLE <database>.<table>;"
   ```

3. **Application smoke tests**
   - Test critical workflows
   - Verify reports and dashboards
   - Check data export functionality

4. **Audit trail verification**
   - Review binlogs to ensure no other changes during recovery
   - Document all recovery actions taken

## Rollback Procedure
If the import causes issues:
1. Put database back in read-only mode
2. Drop the imported data
3. Re-assess recovery strategy
4. Consider restoring entire cluster if corruption spreads

## Post-Recovery Actions
1. **Root cause analysis**
   - Who executed the destructive operation?
   - What process failed?
   - How did it bypass safeguards?

2. **Implement safeguards**
   - Add confirmation prompts for DROP/DELETE/TRUNCATE
   - Implement soft-delete patterns where appropriate
   - Require explicit `--confirm` flags for destructive operations
   - Use database-level triggers to log destructive operations

3. **Improve access controls**
   - Audit who has DELETE/DROP privileges
   - Implement principle of least privilege
   - Require approval for schema changes
   - Use separate read-only credentials for analytics

4. **Enhance monitoring**
   - Alert on sudden table size changes
   - Monitor row count deltas
   - Track schema changes
   - Set up audit log analysis

5. **Update runbooks**
   - Document this specific recovery
   - Update PITR procedures
   - Schedule regular restore drills

## Related Scenarios
- Widespread data corruption
- S3 backup target unavailable
- Backups complete but non-restorable
- Credential compromise

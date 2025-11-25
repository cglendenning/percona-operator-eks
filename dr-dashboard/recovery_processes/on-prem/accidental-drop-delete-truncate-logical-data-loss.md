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
   # List available backups
   aws s3 ls s3://<backup-bucket>/backups/ --recursive
   ```

4. **Restore backup to a SIDE INSTANCE (not production!)**
   ```bash
   # Create a temporary restore environment
   xtrabackup --copy-back --target-dir=/path/to/backup
   ```

5. **Verify data exists on side instance**

6. **Export the recovered data**
   ```bash
   # Use mydumper for large tables
   mydumper --host=<side-instance> --user=root --password=<pass> \
     --database=<database> --tables-list=<table> \
     --outputdir=/tmp/recovery
   ```

7. **Import recovered data to production**
   ```bash
   myloader --host=<prod-host> --user=root --password=<pass> \
     --database=<database> --directory=/tmp/recovery \
     --overwrite-tables
   ```

8. **Verify data integrity and re-enable writes**

## Recovery Targets
- **RTO**: 1-4 hours
- **RPO**: ≤ 5 minutes
- **MTTR**: 2-8 hours

## Expected Data Loss
Up to RPO (5-15 minutes typical)

## Related Scenarios
- Widespread data corruption
- S3 backup target unavailable
- Backups complete but non-restorable

# Widespread Data Corruption (Bad Migration/Script) Recovery Process

## Scenario
Widespread data corruption (bad migration/script)

## Detection Signals
- Integrity checks failing
- Anomaly detection alerts
- Application incidents post-deployment
- Users reporting incorrect data
- Foreign key constraint violations
- Checksums mismatches

## Primary Recovery Method
PITR to pre-change timestamp on clean environment; validate; cutover

### Steps

⚠️ **CRITICAL**: Do NOT make further changes until recovery plan confirmed!

1. **Stop all changes immediately**
   ```bash
   # Set database read-only
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL read_only = ON; SET GLOBAL super_read_only = ON;"
   
   # Stop automated jobs, deployments, scheduled tasks
   ```

2. **Identify the corruption source and timestamp**
   - Review deployment logs
   - Check Git history for recent migrations
   - Find exact time BEFORE corruption occurred
   - Document the bad change for rollback

3. **Assess corruption extent**
   ```bash
   # Check affected tables
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "CHECK TABLE <database>.<table>;"
   
   # Sample data to understand corruption
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM <affected_table> LIMIT 100;"
   ```

4. **Create clean restore environment**
   - Provision separate cluster/namespace
   - Do NOT restore over production!
   - Ensure sufficient resources

5. **Restore backup to pre-corruption time**
   ```bash
   # Find backup before the bad change
   aws s3 ls s3://<backup-bucket>/backups/ --recursive | grep "<date-before-corruption>"
   
   # Restore to clean environment
   xtrabackup --copy-back --target-dir=<backup-path>
   ```

6. **Apply PITR using binlogs**
   ```bash
   # Apply binlogs up to BEFORE corruption
   mysqlbinlog --stop-datetime="2024-01-15 14:25:00" \
     /path/to/binlogs/mysql-bin.* | \
     mysql -uroot -p<pass>
   ```

7. **Validate restored data**
   ```bash
   # Run integrity checks
   mysql -uroot -p<pass> -e "CHECK TABLE <database>.<table>;"
   
   # Verify row counts
   mysql -uroot -p<pass> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Sample data verification
   mysql -uroot -p<pass> -e "SELECT * FROM <table> WHERE <conditions>;"
   
   # Run application smoke tests on restored environment
   ```

8. **Prepare production cutover**
   - Communicate maintenance window to stakeholders
   - Prepare DNS/ingress changes
   - Document rollback plan
   - Get approval from leadership

9. **Execute cutover**
   ```bash
   # Point applications to restored environment
   # Update DNS/load balancers
   # Restart application pods
   
   # Disable read-only on new primary
   kubectl exec -n <new-namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL read_only = OFF; SET GLOBAL super_read_only = OFF;"
   ```

10. **Verify production**
    - Test all critical workflows
    - Monitor error rates
    - Verify data integrity
    - Check application metrics

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
   kubectl exec -n <namespace> <replica-pod> -- mysql -uroot -p<pass> < compensating-migration.sql
   ```

4. **Apply to production if test succeeds**
   ```bash
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> < compensating-migration.sql
   ```

## Recovery Targets
- **RTO**: 2-6 hours
- **RPO**: 5-15 minutes
- **MTTR**: 4-12 hours

## Expected Data Loss
Minutes (to chosen restore point)

## Affected Components
- Database schema
- Application data
- CI/CD pipeline
- Migration scripts

## Assumptions & Prerequisites
- Strict change windows enforced
- Mandatory backup verification before migrations
- All migrations version controlled
- Audit trail of changes exists
- Restore environment available
- Binlog retention covers incident timeframe

## Verification Steps

1. **Data integrity**
   ```bash
   # Run full integrity check
   mysqlcheck -uroot -p<pass> --all-databases --check
   
   # Verify critical tables
   mysql -uroot -p<pass> -e "CHECK TABLE <critical_table>;"
   ```

2. **Row count verification**
   ```bash
   # Compare counts before/after
   mysql -uroot -p<pass> -e "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='<database>';"
   ```

3. **Application tests**
   - Run end-to-end test suite
   - Verify critical user workflows
   - Check reporting/analytics for anomalies

4. **Foreign key consistency**
   ```bash
   mysql -uroot -p<pass> -e "SELECT * FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_TYPE='FOREIGN KEY' AND TABLE_SCHEMA='<database>';"
   ```

## Rollback Procedure
If restoration causes new issues:
1. Keep corrupted database available (don't delete)
2. Assess what went wrong with restoration
3. Consider partial restoration (specific tables only)
4. May need to restore to earlier backup

## Post-Recovery Actions

1. **Root cause analysis**
   - Who deployed the bad change?
   - Why did it pass review?
   - What testing was missed?

2. **Strengthen change controls**
   - Require peer review for migrations
   - Mandatory migration testing on staging
   - Implement migration dry-run mode
   - Add pre-deployment checklist

3. **Improve testing**
   - Add data integrity tests to CI/CD
   - Implement schema validation
   - Add constraint checking
   - Test migrations on production-like data

4. **Enhance monitoring**
   - Alert on row count deltas
   - Monitor foreign key violations
   - Track schema changes
   - Implement anomaly detection on data

5. **Update procedures**
   - Mandatory backup before migrations
   - Require rollback script for every migration
   - Implement blue-green deployment for schema changes
   - Schedule regular restore drills

## Related Scenarios
- Accidental DROP/DELETE/TRUNCATE
- Backups complete but non-restorable
- Credential compromise (if malicious)
- Percona Operator misconfiguration

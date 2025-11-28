# Audit Log Corruption or Loss (Compliance Violation) Recovery Process

## Primary Recovery Method

1. **Identify the audit log issue**
   ```bash
   # Check audit log file status
   kubectl exec -n <namespace> <pod> -- ls -lh /var/lib/mysql/audit.log*
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'audit_log%';"
   
   # Check for audit log corruption
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM mysql.audit_log WHERE event_time >= DATE_SUB(NOW(), INTERVAL 1 DAY) LIMIT 10;"
   
   # Check audit log file integrity
   kubectl exec -n <namespace> <pod> -- file /var/lib/mysql/audit.log
   ```

2. **Restore audit logs from backup**
   ```bash
   # Find audit log backups in MinIO
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<backup-bucket>/audit-logs/ --recursive
   
   # Download audit log backup
   kubectl exec -n minio-operator <minio-pod> -- mc cp local/<backup-bucket>/audit-logs/<audit-log-backup> /tmp/audit-log-restore/
   
   # Restore audit log file
   kubectl cp <namespace>/<pod>:/tmp/audit-log-restore/audit.log /tmp/audit.log
   kubectl cp /tmp/audit.log <namespace>/<pod>:/var/lib/mysql/audit.log
   
   # Set proper permissions
   kubectl exec -n <namespace> <pod> -- chown mysql:mysql /var/lib/mysql/audit.log
   kubectl exec -n <namespace> <pod> -- chmod 640 /var/lib/mysql/audit.log
   ```

3. **Regenerate audit trail from binlogs if possible**
   ```bash
   # If audit logs cannot be restored, attempt to reconstruct from binlogs
   # Extract relevant events from binlogs
   kubectl exec -n <namespace> <pod> -- mysqlbinlog --start-datetime="<start-time>" --stop-datetime="<end-time>" /var/lib/mysql/binlog.* | grep -i "audit\|compliance"
   
   # Note: This is a partial reconstruction and may not capture all audit events
   # Document the gap for compliance reporting
   ```

4. **Document gap for auditors**
   ```bash
   # Create gap documentation
   # Document:
   # - Time period of missing/corrupted audit logs
   # - Root cause of corruption/loss
   # - Actions taken to restore
   # - Compensating controls implemented
   # - Steps taken to prevent recurrence
   
   # Store documentation in compliance system
   ```

5. **Verify audit logging is restored**
   ```bash
   # Verify audit log is writing
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'audit_log%';"
   
   # Test audit log capture
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT 1;"
   kubectl exec -n <namespace> <pod> -- tail -5 /var/lib/mysql/audit.log
   
   # Verify audit log file is growing
   kubectl exec -n <namespace> <pod> -- ls -lh /var/lib/mysql/audit.log
   ```

## Alternate/Fallback Method

1. **Reconstruct audit trail from application logs**
   ```bash
   # Extract relevant events from application logs
   # This provides partial audit trail reconstruction
   # Focus on critical events (authentication, data access, schema changes)
   
   # Review application logs for the time period
   kubectl logs -n <app-namespace> -l app=<app-name> --since-time="<start-time>" --until-time="<end-time>" | grep -i "auth\|access\|query\|transaction"
   ```

2. **Implement compensating controls**
   ```bash
   # Enable additional logging
   # Increase audit log verbosity temporarily
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL audit_log_policy = 'ALL';"
   
   # Enable general query log as backup
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL general_log = 'ON';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL log_output = 'FILE';"
   ```

## Recovery Targets

- **Restore Time Objective**: 2 hours
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 2-8 hours

## Expected Data Loss

Audit trail gaps (compliance risk)

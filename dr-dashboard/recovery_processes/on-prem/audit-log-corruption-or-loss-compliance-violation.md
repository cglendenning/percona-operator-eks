# Audit Log Corruption or Loss (Compliance Violation) Recovery Process

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
read -p "Enter SeaweedFS S3 endpoint URL (e.g. http://seaweedfs-filer.seaweedfs-primary.svc:8333): " SEAWEEDFS_ENDPOINT
```





## Primary Recovery Method

1. **Identify the audit log issue**
   ```bash
   # Check audit log file status
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- ls -lh /var/lib/mysql/audit.log*
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW VARIABLES LIKE 'audit_log%';"
   
   # Check for audit log corruption
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT * FROM mysql.audit_log WHERE event_time >= DATE_SUB(NOW(), INTERVAL 1 DAY) LIMIT 10;"
   
   # Check audit log file integrity
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- file /var/lib/mysql/audit.log
   ```

2. **Restore audit logs from backup**
   ```bash
   # Find audit log backups in SeaweedFS (export AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY from backup secret first)
   aws s3 ls s3://<backup-bucket>/audit-logs/ --endpoint-url ${SEAWEEDFS_ENDPOINT} --recursive
   
   # Download audit log backup
   aws s3 cp s3://<backup-bucket>/audit-logs/<audit-log-backup> /tmp/audit-log-restore/ --recursive --endpoint-url ${SEAWEEDFS_ENDPOINT}
   
   # Restore audit log file
   kubectl cp ${NAMESPACE}/${POD_NAME}:/tmp/audit-log-restore/audit.log /tmp/audit.log
   kubectl cp /tmp/audit.log ${NAMESPACE}/${POD_NAME}:/var/lib/mysql/audit.log
   
   # Set proper permissions
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- chown mysql:mysql /var/lib/mysql/audit.log
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- chmod 640 /var/lib/mysql/audit.log
   ```

3. **Regenerate audit trail from binlogs if possible**
   ```bash
   # If audit logs cannot be restored, attempt to reconstruct from binlogs
   # Extract relevant events from binlogs
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysqlbinlog --start-datetime="<start-time>" --stop-datetime="<end-time>" /var/lib/mysql/binlog.* | grep -i "audit\|compliance"
   
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
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW VARIABLES LIKE 'audit_log%';"
   
   # Test audit log capture
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- tail -5 /var/lib/mysql/audit.log
   
   # Verify audit log file is growing
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- ls -lh /var/lib/mysql/audit.log
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
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL audit_log_policy = 'ALL';"
   
   # Enable general query log as backup
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL general_log = 'ON';"
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL log_output = 'FILE';"
   ```

## Recovery Targets

- **Restore Time Objective**: 2 hours
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 2-8 hours

## Expected Data Loss

Audit trail gaps (compliance risk)

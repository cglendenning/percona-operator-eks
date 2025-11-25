# Credential Compromise (DB or S3 Keys) Recovery Process

## Scenario
Credential compromise (DB or S3 keys)

## Detection Signals
- Anomalous access patterns
- Login from unusual locations/IPs
- AWS GuardDuty alerts
- SIEM alerts for suspicious behavior
- IAM CloudTrail alerts
- Failed authentication attempts
- Unusual data access patterns
- Data exfiltration detected

## Primary Recovery Method
Rotate credentials; revoke sessions; rotate S3/IAM; audit access

### Steps

⚠️ **CRITICAL**: Act fast to limit unauthorized access!

1. **Identify compromised credentials**
   ```bash
   # Check CloudTrail for unusual activity
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=Username,AttributeValue=<suspected-user> \
     --max-items 100
   
   # Check database access logs
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM mysql.general_log WHERE user_host LIKE '%<ip>%' ORDER BY event_time DESC LIMIT 100;"
   
   # Review GuardDuty findings
   aws guardduty list-findings --detector-id <detector-id>
   ```

2. **Immediately rotate database credentials**
   ```bash
   # Generate new password
   NEW_PASS=$(openssl rand -base64 32)
   
   # Update database password
   kubectl exec -n percona <pod> -- mysql -uroot -p<current-pass> -e "ALTER USER 'root'@'%' IDENTIFIED BY '${NEW_PASS}';"
   kubectl exec -n percona <pod> -- mysql -uroot -p<current-pass> -e "ALTER USER 'application'@'%' IDENTIFIED BY '${NEW_PASS}';"
   kubectl exec -n percona <pod> -- mysql -uroot -p<current-pass> -e "FLUSH PRIVILEGES;"
   
   # Update Kubernetes secret
   kubectl create secret generic mysql-credentials \
     --from-literal=root-password="${NEW_PASS}" \
     --from-literal=app-password="${NEW_PASS}" \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

3. **Revoke active database sessions**
   ```bash
   # List active connections
   kubectl exec -n percona <pod> -- mysql -uroot -p<new-pass> -e "SHOW PROCESSLIST;"
   
   # Kill suspicious connections
   kubectl exec -n percona <pod> -- mysql -uroot -p<new-pass> -e "KILL <process-id>;"
   
   # Kill all non-system connections if needed
   kubectl exec -n percona <pod> -- mysql -uroot -p<new-pass> -e "
   SELECT GROUP_CONCAT(CONCAT('KILL ',id,';') SEPARATOR ' ')
   FROM information_schema.PROCESSLIST
   WHERE user != 'system user' AND id != CONNECTION_ID();
   " | tail -1 | kubectl exec -n percona <pod> -- mysql -uroot -p<new-pass>
   ```

4. **Rotate IAM/S3 credentials**
   ```bash
   # Deactivate old access keys
   aws iam list-access-keys --user-name <compromised-user>
   aws iam update-access-key --access-key-id <old-key> --status Inactive --user-name <user>
   
   # Create new access keys
   aws iam create-access-key --user-name <user>
   
   # Update Kubernetes secret
   kubectl create secret generic s3-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=<new-key> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<new-secret> \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Delete old access keys
   aws iam delete-access-key --access-key-id <old-key> --user-name <user>
   ```

5. **Update application configurations**
   ```bash
   # Restart applications to pick up new credentials
   kubectl rollout restart deployment -n <app-namespace> <app-deployment>
   
   # Verify applications can connect
   kubectl logs -n <app-namespace> <app-pod> | grep -i "database connection"
   ```

6. **Audit data access during compromise window**
   ```bash
   # Check what data was accessed
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "
   SELECT * FROM mysql.general_log
   WHERE event_time BETWEEN '<start-time>' AND '<end-time>'
   AND (command_type = 'Query' OR command_type = 'Execute')
   ORDER BY event_time;
   "
   
   # Check for data exfiltration
   # Look for large SELECT queries or mysqldump operations
   ```

7. **Review and restrict access**
   ```bash
   # Audit database user permissions
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT user, host FROM mysql.user;"
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW GRANTS FOR 'application'@'%';"
   
   # Remove unnecessary privileges
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "REVOKE ALL PRIVILEGES ON *.* FROM 'user'@'%'; GRANT SELECT, INSERT, UPDATE ON app_db.* TO 'user'@'%';"
   
   # Restrict access by IP if possible
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE USER 'app'@'10.0.0.0/255.0.0.0' IDENTIFIED BY '<pass>'; GRANT SELECT, INSERT, UPDATE ON app_db.* TO 'app'@'10.0.0.0/255.0.0.0';"
   ```

8. **Check for backdoors**
   ```bash
   # Look for unauthorized users
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT user, host, authentication_string FROM mysql.user WHERE user NOT IN ('root', 'mysql.sys', 'application');"
   
   # Check for suspicious stored procedures or triggers
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');"
   
   # Check for event scheduler jobs
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW EVENTS;"
   ```

## Alternate/Fallback Method
If suspected data tamper, execute PITR to clean point

### Steps

1. **If data was modified maliciously**
   - Identify last known good timestamp
   - Restore from backup before compromise
   - Apply PITR using binlogs (see "Accidental DROP/DELETE" runbook)

2. **Verify data integrity**
   - Run checksums on critical tables
   - Compare row counts to expected values
   - Review audit logs for unauthorized changes

## Recovery Targets
- **RTO**: 30-120 minutes
- **RPO**: 0-15 minutes (if PITR needed)
- **MTTR**: 2-8 hours

## Expected Data Loss
Potential rollback of recent writes if PITR required

## Affected Components
- Database users and credentials
- IAM users and roles
- S3 buckets and access keys
- CI/CD secrets
- Application configurations

## Assumptions & Prerequisites
- Secret rotation via Fleet/GitOps
- Least privilege principle enforced
- MFA on admin accounts
- Audit logging enabled
- SIEM or log aggregation in place

## Verification Steps

1. **Verify new credentials work**
   ```bash
   # Test database login
   kubectl exec -n percona <pod> -- mysql -uroot -p<new-pass> -e "SELECT 1;"
   
   # Test from application
   kubectl logs -n <app-namespace> <app-pod> --tail=20
   ```

2. **Verify old credentials revoked**
   ```bash
   # Try old password (should fail)
   kubectl exec -n percona <pod> -- mysql -uroot -p<old-pass> -e "SELECT 1;" 2>&1 | grep "Access denied"
   
   # Check IAM access keys
   aws iam list-access-keys --user-name <user>
   # Old keys should be deleted or inactive
   ```

3. **Monitor for unauthorized access attempts**
   ```bash
   # Watch authentication failures
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT * FROM mysql.general_log WHERE argument LIKE '%Access denied%';"
   
   # Monitor GuardDuty
   aws guardduty get-findings --detector-id <id> --finding-ids <findings>
   ```

4. **Verify no backdoors remain**
   - Re-run backdoor checks from step 8 above
   - Full security scan of database

## Rollback Procedure
If rotation causes application issues:
1. Keep new credentials active
2. Temporarily allow both old and new (if absolutely necessary)
3. Fix application configuration issues
4. Remove old credentials once apps updated

## Post-Recovery Actions

1. **Complete security audit**
   - How were credentials compromised?
   - Phishing? Leaked in code? Stolen from laptop?
   - What was accessed during compromise?

2. **Implement preventive measures**
   - Enable MFA on all accounts
   - Use IAM roles instead of access keys where possible
   - Implement secrets management (Vault, AWS Secrets Manager)
   - Rotate credentials regularly (automated)
   - Use short-lived credentials

3. **Enhance monitoring**
   - Alert on login anomalies
   - Monitor for privilege escalation
   - Track data access patterns
   - Implement User and Entity Behavior Analytics (UEBA)

4. **Update procedures**
   - Document credential rotation process
   - Automate secret rotation
   - Implement break-glass procedures
   - Schedule regular credential audits

5. **Security training**
   - Credential hygiene training
   - Phishing awareness
   - Secure coding practices (don't commit secrets!)
   - Incident reporting procedures

6. **Legal and compliance**
   - Determine if notification required
   - Report to regulators if needed
   - Review insurance coverage
   - Document incident for audit

## Prevention for Future

- **Secrets Management** - Use Vault, AWS Secrets Manager, etc.
- **Least Privilege** - Minimal permissions for each user/app
- **MFA Everywhere** - On all accounts
- **Automated Rotation** - Regular credential rotation
- **No Hardcoded Secrets** - Never in code or configs
- **Audit Logging** - Track all credential usage
- **Monitoring** - Alert on anomalous access
- **Code Scanning** - Detect secrets in commits
- **Break Glass Procedures** - For emergencies only

## Related Scenarios
- Ransomware attack
- Accidental DROP/DELETE/TRUNCATE (if data tampered)
- Widespread data corruption
- S3 backup target unavailable (if S3 keys compromised)

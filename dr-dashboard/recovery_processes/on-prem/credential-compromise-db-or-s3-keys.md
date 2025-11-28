# Credential Compromise (DB or MinIO Keys) Recovery Process

## Primary Recovery Method
Rotate credentials; revoke sessions; rotate MinIO credentials; audit access

### Steps

⚠️ **CRITICAL**: Act fast to limit unauthorized access!

1. **Immediately rotate database credentials**
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

2. **Revoke active database sessions**
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

3. **Rotate MinIO credentials**
   ```bash
   # Create new MinIO user
   kubectl exec -n minio-operator <minio-pod> -- mc admin user add local <new-user> <new-password>
   kubectl exec -n minio-operator <minio-pod> -- mc admin policy attach local readwrite --user <new-user>
   
   # Remove old user or deactivate
   kubectl exec -n minio-operator <minio-pod> -- mc admin user remove local <old-user>
   
   # Update Kubernetes secret
   kubectl create secret generic minio-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=<new-user> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<new-password> \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment <backup-deployment> -n percona
   ```

4. **Update application configurations**
   ```bash
   # Restart applications to pick up new credentials
   kubectl rollout restart deployment -n <app-namespace> <app-deployment>
   
   # Verify applications can connect
   kubectl logs -n <app-namespace> <app-pod> | grep -i "database connection"
   ```

5. **Verify service is restored**
   ```bash
   # Test database login with new credentials
   kubectl exec -n percona <pod> -- mysql -uroot -p<new-pass> -e "SELECT 1;"
   
   # Test write operations from application
   # Verify application logs show successful connections
   ```

## Alternate/Fallback Method
If suspected data tamper, execute PITR to clean point

### Steps

1. **If data was modified maliciously**
   - Identify last known good timestamp
   - Restore from backup before compromise
   - Apply PITR using binlogs (see "Accidental DROP/DELETE" runbook)

2. **Verify service is restored**
   ```bash
   # Verify data integrity
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Test write operations from application
   ```

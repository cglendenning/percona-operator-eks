# Credential Compromise (DB or S3 Keys) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter new AWS access key ID: " NEW_ACCESS_KEY
read -sp "Enter new AWS secret key: " NEW_SECRET_KEY; echo
read -sp "Enter new password: " NEW_PASS; echo
```





## Primary Recovery Method
Rotate credentials; revoke sessions; rotate S3/IAM; audit access

### Steps

⚠️ **CRITICAL**: Act fast to limit unauthorized access!

1. **Immediately rotate database credentials**
   ```bash
   # Generate new password
   NEW_PASS=$(openssl rand -base64 32)
   
   # Update database password
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<current-pass> -e "ALTER USER 'root'@'%' IDENTIFIED BY '${NEW_PASS}';"
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<current-pass> -e "ALTER USER 'application'@'%' IDENTIFIED BY '${NEW_PASS}';"
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<current-pass> -e "FLUSH PRIVILEGES;"
   
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
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<new-pass> -e "SHOW PROCESSLIST;"
   
   # Kill suspicious connections
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<new-pass> -e "KILL <process-id>;"
   
   # Kill all non-system connections if needed
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<new-pass> -e "
   SELECT GROUP_CONCAT(CONCAT('KILL ',id,';') SEPARATOR ' ')
   FROM information_schema.PROCESSLIST
   WHERE user != 'system user' AND id != CONNECTION_ID();
   " | tail -1 | kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<new-pass>
   ```

3. **Rotate IAM/S3 credentials**
   ```bash
   # Deactivate old access keys
   aws iam list-access-keys --user-name <compromised-user>
   aws iam update-access-key --access-key-id <old-key> --status Inactive --user-name <user>
   
   # Create new access keys
   aws iam create-access-key --user-name <user>
   
   # Update Kubernetes secret
   kubectl create secret generic s3-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=${NEW_ACCESS_KEY} \
     --from-literal=AWS_SECRET_ACCESS_KEY=${NEW_SECRET_KEY} \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Delete old access keys
   aws iam delete-access-key --access-key-id <old-key> --user-name <user>
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
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p<new-pass> -e "SELECT 1;"
   
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
   kubectl exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Test write operations from application
   ```

# Encryption Key Rotation Failure (Database or Backup Encryption) Recovery Process

## Primary Recovery Method

1. **Identify encryption key rotation failure**
   ```bash
   # Check key rotation job status
   kubectl get jobs -n <namespace> | grep key-rotation
   kubectl logs -n <namespace> <key-rotation-job-pod>
   
   # Check encryption/decryption errors
   kubectl logs -n <namespace> <pxc-pod> | grep -i "encryption\|decryption\|key"
   
   # Check database encryption status
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SHOW VARIABLES LIKE 'innodb_encrypt%';"
   ```

2. **Rollback key rotation**
   ```bash
   # Stop key rotation job if running
   kubectl delete job -n <namespace> <key-rotation-job>
   
   # Restore previous key
   kubectl get secret -n <namespace> <encryption-key-secret> -o yaml > key-backup.yaml
   kubectl apply -f key-backup.yaml
   
   # Verify previous key is active
   kubectl get secret -n <namespace> <encryption-key-secret>
   ```

3. **Restore previous key**
   ```bash
   # Get previous key from backup
   kubectl get secret -n <namespace> <encryption-key-secret-backup> -o yaml
   
   # Restore previous key
   kubectl create secret generic <encryption-key-secret> \
     --from-literal=key=<previous-key> \
     -n <namespace> \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. **Fix key rotation process**
   ```bash
   # Review key rotation configuration
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml | grep -A 10 encryption
   
   # Update key rotation configuration
   kubectl patch perconaxtradbcluster -n <namespace> <cluster-name> --type=json -p='[
     {
       "op": "replace",
       "path": "/spec/pxc/encryption",
       "value": {
         "key": "<correct-key>"
       }
     }
   ]'
   ```

5. **Retry rotation after validation**
   ```bash
   # Validate key rotation process
   # Test key rotation in non-production first
   # Retry key rotation
   kubectl apply -f <key-rotation-job.yaml>
   
   # Monitor key rotation
   kubectl logs -n <namespace> <key-rotation-job-pod> -f
   ```

6. **Verify service is restored**
   ```bash
   # Check encryption status
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SHOW VARIABLES LIKE 'innodb_encrypt%';"
   
   # Test database operations
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SELECT 1;"
   
   # Check backup encryption
   kubectl get perconaxtradbclusterbackup -n <namespace>
   ```

## Alternate/Fallback Method

1. **Use backup encryption keys**
   ```bash
   # Get backup encryption key
   kubectl get secret -n <namespace> <backup-encryption-key-secret>
   
   # Use backup key for restore
   kubectl create secret generic <encryption-key-secret> \
     --from-literal=key=<backup-key> \
     -n <namespace>
   ```

2. **Restore from unencrypted backup if available**
   ```bash
   # If unencrypted backup exists
   # Restore from unencrypted backup
   kubectl apply -f <restore-from-unencrypted-backup.yaml>
   ```

3. **Re-encrypt data with new keys**
   ```bash
   # After restore, re-encrypt data
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "ALTER TABLE <table-name> ENCRYPTION='Y';"
   ```

## Recovery Targets

- **Restore Time Objective**: 90 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 1-4 hours

## Expected Data Loss

None if handled correctly; potential data loss if keys are lost

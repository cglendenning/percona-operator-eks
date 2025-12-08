# Encryption Key Rotation Failure (Database or Backup Encryption) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -p "Enter PXC cluster name: " CLUSTER_NAME
```





## Primary Recovery Method

1. **Identify encryption key rotation failure**
   ```bash
   # Check key rotation job status
   kubectl get jobs -n ${NAMESPACE} | grep key-rotation
   kubectl logs -n ${NAMESPACE} <key-rotation-job-pod>
   
   # Check AWS KMS errors
   aws kms describe-key --key-id <key-id>
   aws kms get-key-rotation-status --key-id <key-id>
   
   # Check encryption/decryption errors
   kubectl logs -n ${NAMESPACE} <pxc-pod> | grep -i "encryption\|decryption\|key"
   
   # Check database encryption status
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW VARIABLES LIKE 'innodb_encrypt%';"
   ```

2. **Rollback key rotation**
   ```bash
   # Stop key rotation job if running
   kubectl delete job -n ${NAMESPACE} <key-rotation-job>
   
   # Restore previous key from AWS KMS
   aws kms disable-key-rotation --key-id <new-key-id>
   aws kms enable-key --key-id <previous-key-id>
   
   # Update Kubernetes secret with previous key
   kubectl get secret -n ${NAMESPACE} <encryption-key-secret> -o yaml > key-backup.yaml
   kubectl apply -f key-backup.yaml
   ```

3. **Restore previous key from AWS KMS**
   ```bash
   # Get previous key from AWS KMS
   aws kms describe-key --key-id <previous-key-id>
   
   # Restore previous key
   kubectl create secret generic <encryption-key-secret> \
     --from-literal=key=<previous-key-arn> \
     -n ${NAMESPACE} \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. **Fix key rotation process**
   ```bash
   # Review key rotation configuration
   kubectl get perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} -o yaml | grep -A 10 encryption
   
   # Update key rotation configuration
   kubectl patch perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} --type=json -p='[
     {
       "op": "replace",
       "path": "/spec/pxc/encryption",
       "value": {
         "key": "<correct-key-arn>"
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
   kubectl logs -n ${NAMESPACE} <key-rotation-job-pod> -f
   ```

6. **Verify service is restored**
   ```bash
   # Check encryption status
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW VARIABLES LIKE 'innodb_encrypt%';"
   
   # Test database operations
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT 1;"
   
   # Check backup encryption
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE}
   
   # Verify AWS KMS key status
   aws kms describe-key --key-id <key-id>
   ```

## Alternate/Fallback Method

1. **Use backup encryption keys**
   ```bash
   # Get backup encryption key from AWS KMS
   aws kms describe-key --key-id <backup-key-id>
   
   # Use backup key for restore
   kubectl create secret generic <encryption-key-secret> \
     --from-literal=key=<backup-key-arn> \
     -n ${NAMESPACE}
   ```

2. **Restore from unencrypted backup if available**
   ```bash
   # If unencrypted backup exists in S3
   aws s3 ls s3://<backup-bucket>/backups/
   
   # Restore from unencrypted backup
   kubectl apply -f <restore-from-unencrypted-backup.yaml>
   ```

3. **Re-encrypt data with new keys**
   ```bash
   # After restore, re-encrypt data
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "ALTER TABLE <table-name> ENCRYPTION='Y';"
   ```

## Recovery Targets

- **Restore Time Objective**: 90 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 1-4 hours

## Expected Data Loss

None if handled correctly; potential data loss if keys are lost

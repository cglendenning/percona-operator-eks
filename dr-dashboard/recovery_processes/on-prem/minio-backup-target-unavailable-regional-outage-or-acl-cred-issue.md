# MinIO Backup Target Unavailable (Regional Outage or ACL/Credential Issue) Recovery Process

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
read -p "Enter backup bucket name: " BUCKET_NAME
read -p "Enter secondary/fallback bucket name: " SECONDARY_BUCKET_NAME
read -p "Enter backup pod name: " BACKUP_POD
read -p "Enter MinIO pod name: " MINIO_POD
read -p "Enter credentials secret name: " SECRET_NAME
read -p "Enter MinIO endpoint URL: " MINIO_ENDPOINT
read -p "Enter secondary MinIO endpoint URL: " SECONDARY_MINIO_ENDPOINT
read -p "Enter backup deployment name: " BACKUP_DEPLOYMENT
read -p "Enter new MinIO username: " NEW_MINIO_USER
read -sp "Enter new MinIO password: " NEW_MINIO_PASSWORD; echo
read -p "Enter path to test backup CR YAML: " TEST_BACKUP_CR
```





## Primary Recovery Method

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n ${NAMESPACE} ${BACKUP_POD} --tail=100
   
   # Test MinIO connectivity
   kubectl exec -n minio-operator ${MINIO_POD} -- mc ls local/${BUCKET_NAME}/ 2>&1
   
   # Check MinIO credentials
   kubectl get secret -n ${NAMESPACE} ${SECRET_NAME} -o yaml
   ```

2. **Buffer backups locally**
   ```bash
   # Create PVC for temporary backup storage
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: temp-backup-storage
     namespace: ${NAMESPACE}
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 500Gi
   EOF
   
   # Update backup configuration to write to local PVC temporarily
   kubectl edit perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME}
   ```

3. **Failover to secondary MinIO instance if available**
   ```bash
   # Update backup configuration to point to secondary MinIO
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         minio:
           s3:
             endpointUrl: https://${SECONDARY_MINIO_ENDPOINT}:9000
   '
   ```

4. **Rotate MinIO credentials if credential issue**
   ```bash
   # Create new MinIO access keys
   kubectl exec -n minio-operator ${MINIO_POD} -- mc admin user add local ${NEW_MINIO_USER} ${NEW_MINIO_PASSWORD}
   kubectl exec -n minio-operator ${MINIO_POD} -- mc admin policy attach local readwrite --user ${NEW_MINIO_USER}
   
   # Update Kubernetes secret
   kubectl create secret generic minio-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=${NEW_MINIO_USER} \
     --from-literal=AWS_SECRET_ACCESS_KEY=${NEW_MINIO_PASSWORD} \
     -n ${NAMESPACE} \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment ${BACKUP_DEPLOYMENT} -n ${NAMESPACE}
   ```

5. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE}
   
   # Create a test backup
   kubectl apply -f ${TEST_BACKUP_CR}
   
   # Monitor backup job
   kubectl get jobs -n ${NAMESPACE} -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to secondary DC object store/NAS**
   ```bash
   # Configure backup to alternative target
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         minio-secondary:
           type: s3
           s3:
             bucket: ${SECONDARY_BUCKET_NAME}
             endpointUrl: https://${SECONDARY_MINIO_ENDPOINT}:9000
             region: us-east-1
   '
   ```

2. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl apply -f ${TEST_BACKUP_CR}
   
   # Verify backup completes successfully
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 1-3 hours

## Expected Data Loss

Risk only if outage spans retention window

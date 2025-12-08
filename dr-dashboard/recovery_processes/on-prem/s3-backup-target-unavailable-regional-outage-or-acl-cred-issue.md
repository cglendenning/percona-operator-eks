# MinIO Backup Target Unavailable Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
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
```





## Primary Recovery Method
Buffer locally; failover to secondary MinIO instance; rotate credentials

### Steps

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n percona ${BACKUP_POD} --tail=100
   
   # Test MinIO connectivity
   kubectl exec -n minio-operator ${MINIO_POD} -- mc ls local/${BUCKET_NAME}/ 2>&1
   
   # Check MinIO credentials
   kubectl get secret -n percona ${SECRET_NAME} -o yaml
   ```

2. **Immediate action: Buffer backups locally**
   ```bash
   # Create PVC for temporary backup storage
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: temp-backup-storage
     namespace: percona
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 500Gi
   EOF
   
   # Update backup configuration to write to local PVC temporarily
   kubectl edit perconaxtradbcluster -n percona ${CLUSTER_NAME}
   ```

3. **If credential issue: Rotate MinIO credentials**
   ```bash
   # Create new MinIO access keys
   kubectl exec -n minio-operator ${MINIO_POD} -- mc admin user add local ${NEW_MINIO_USER} ${NEW_MINIO_PASSWORD}
   kubectl exec -n minio-operator ${MINIO_POD} -- mc admin policy attach local readwrite --user ${NEW_MINIO_USER}
   
   # Update Kubernetes secret
   kubectl create secret generic minio-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=${NEW_MINIO_USER} \
     --from-literal=AWS_SECRET_ACCESS_KEY=${NEW_MINIO_PASSWORD} \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment ${BACKUP_DEPLOYMENT} -n percona
   ```

4. **If MinIO service issue: Restart or failover**
   ```bash
   # Check MinIO pod status
   kubectl get pods -n minio-operator
   
   # Restart MinIO if needed
   kubectl rollout restart statefulset <minio-sts> -n minio-operator
   
   # Or failover to secondary MinIO instance if available
   # Update backup configuration to point to secondary MinIO
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n percona --type=merge -p '
   spec:
     backup:
       storages:
         minio:
           s3:
             endpointUrl: https://${SECONDARY_MINIO_ENDPOINT}:9000
   '
   ```

5. **If bucket issue: Fix bucket permissions**
   ```bash
   # Check bucket exists
   kubectl exec -n minio-operator ${MINIO_POD} -- mc ls local/${BUCKET_NAME}
   
   # Create bucket if missing
   kubectl exec -n minio-operator ${MINIO_POD} -- mc mb local/${BUCKET_NAME}
   
   # Set bucket policy
   kubectl exec -n minio-operator ${MINIO_POD} -- mc anonymous set download local/${BUCKET_NAME}
   ```

6. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl exec -n percona ${BACKUP_POD} -- xtrabackup --backup --target-dir=/tmp/test-backup
   
   # Monitor backup job
   kubectl get jobs -n percona -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method
Temporarily write backups to secondary DC object store/NAS

### Steps

1. **Set up alternative storage**
   - MinIO in secondary DC
   - NFS/NAS storage
   - On-premises object storage

2. **Configure backup to alternative target**
   ```bash
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n percona --type=merge -p '
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

3. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl exec -n percona ${BACKUP_POD} -- xtrabackup --backup --target-dir=/tmp/test-backup
   
   # Verify backup completes successfully
   ```

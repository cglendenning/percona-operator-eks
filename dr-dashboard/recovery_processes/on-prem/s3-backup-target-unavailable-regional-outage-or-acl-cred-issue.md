# MinIO Backup Target Unavailable Recovery Process

## Primary Recovery Method
Buffer locally; failover to secondary MinIO instance; rotate credentials

### Steps

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n percona <backup-pod> --tail=100
   
   # Test MinIO connectivity
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<bucket-name>/ 2>&1
   
   # Check MinIO credentials
   kubectl get secret -n percona <minio-secret> -o yaml
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
   kubectl edit perconaxtradbcluster -n percona <cluster-name>
   ```

3. **If credential issue: Rotate MinIO credentials**
   ```bash
   # Create new MinIO access keys
   kubectl exec -n minio-operator <minio-pod> -- mc admin user add local <new-user> <new-password>
   kubectl exec -n minio-operator <minio-pod> -- mc admin policy attach local readwrite --user <new-user>
   
   # Update Kubernetes secret
   kubectl create secret generic minio-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=<new-user> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<new-password> \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment <backup-deployment> -n percona
   ```

4. **If MinIO service issue: Restart or failover**
   ```bash
   # Check MinIO pod status
   kubectl get pods -n minio-operator
   
   # Restart MinIO if needed
   kubectl rollout restart statefulset <minio-sts> -n minio-operator
   
   # Or failover to secondary MinIO instance if available
   # Update backup configuration to point to secondary MinIO
   kubectl patch perconaxtradbcluster <cluster-name> -n percona --type=merge -p '
   spec:
     backup:
       storages:
         minio:
           s3:
             endpointUrl: https://<secondary-minio-endpoint>:9000
   '
   ```

5. **If bucket issue: Fix bucket permissions**
   ```bash
   # Check bucket exists
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<bucket-name>
   
   # Create bucket if missing
   kubectl exec -n minio-operator <minio-pod> -- mc mb local/<bucket-name>
   
   # Set bucket policy
   kubectl exec -n minio-operator <minio-pod> -- mc anonymous set download local/<bucket-name>
   ```

6. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl exec -n percona <backup-pod> -- xtrabackup --backup --target-dir=/tmp/test-backup
   
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
   kubectl patch perconaxtradbcluster <cluster-name> -n percona --type=merge -p '
   spec:
     backup:
       storages:
         minio-secondary:
           type: s3
           s3:
             bucket: <alternative-bucket>
             endpointUrl: https://<secondary-minio-endpoint>:9000
             region: us-east-1
   '
   ```

3. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl exec -n percona <backup-pod> -- xtrabackup --backup --target-dir=/tmp/test-backup
   
   # Verify backup completes successfully
   ```

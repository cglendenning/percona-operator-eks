# MinIO Backup Target Unavailable (Regional Outage or ACL/Credential Issue) Recovery Process

## Primary Recovery Method

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n <namespace> <backup-pod> --tail=100
   
   # Test MinIO connectivity
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<bucket-name>/ 2>&1
   
   # Check MinIO credentials
   kubectl get secret -n <namespace> <minio-secret> -o yaml
   ```

2. **Buffer backups locally**
   ```bash
   # Create PVC for temporary backup storage
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: temp-backup-storage
     namespace: <namespace>
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 500Gi
   EOF
   
   # Update backup configuration to write to local PVC temporarily
   kubectl edit perconaxtradbcluster -n <namespace> <cluster-name>
   ```

3. **Failover to secondary MinIO instance if available**
   ```bash
   # Update backup configuration to point to secondary MinIO
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
   spec:
     backup:
       storages:
         minio:
           s3:
             endpointUrl: https://<secondary-minio-endpoint>:9000
   '
   ```

4. **Rotate MinIO credentials if credential issue**
   ```bash
   # Create new MinIO access keys
   kubectl exec -n minio-operator <minio-pod> -- mc admin user add local <new-user> <new-password>
   kubectl exec -n minio-operator <minio-pod> -- mc admin policy attach local readwrite --user <new-user>
   
   # Update Kubernetes secret
   kubectl create secret generic minio-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=<new-user> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<new-password> \
     -n <namespace> \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment <backup-deployment> -n <namespace>
   ```

5. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl get perconaxtradbclusterbackup -n <namespace>
   
   # Create a test backup
   kubectl apply -f <test-backup-cr.yaml>
   
   # Monitor backup job
   kubectl get jobs -n <namespace> -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to secondary DC object store/NAS**
   ```bash
   # Configure backup to alternative target
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
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

2. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl apply -f <test-backup-cr.yaml>
   
   # Verify backup completes successfully
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 1-3 hours

## Expected Data Loss

Risk only if outage spans retention window

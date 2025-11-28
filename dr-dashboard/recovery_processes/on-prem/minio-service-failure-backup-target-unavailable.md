# MinIO Service Failure (Backup Target Unavailable) Recovery Process

## Primary Recovery Method

1. **Identify MinIO service failure**
   ```bash
   # Check MinIO pod status
   kubectl get pods -n minio-operator -l app=minio
   kubectl describe pod -n minio-operator <minio-pod-name>
   
   # Check MinIO logs
   kubectl logs -n minio-operator <minio-pod-name> --tail=100
   
   # Check backup job errors
   kubectl get jobs -n <namespace> | grep backup
   kubectl logs -n <namespace> <backup-job-pod> --tail=100
   ```

2. **Restart MinIO pods**
   ```bash
   # Restart MinIO StatefulSet
   kubectl rollout restart statefulset <minio-sts> -n minio-operator
   
   # Wait for pods to restart
   kubectl get pods -n minio-operator -w
   
   # Verify MinIO is healthy
   kubectl exec -n minio-operator <minio-pod> -- mc admin info local
   ```

3. **Failover to secondary MinIO instance if available**
   ```bash
   # Check if secondary MinIO instance exists
   kubectl get pods -n minio-operator -l app=minio-secondary
   
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

4. **Buffer backups locally if MinIO unavailable**
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
   
   # Update backup configuration to use local storage temporarily
   kubectl edit perconaxtradbcluster -n <namespace> <cluster-name>
   ```

5. **Verify service is restored**
   ```bash
   # Test MinIO connectivity
   kubectl exec -n minio-operator <minio-pod> -- mc ls local/<bucket-name>/
   
   # Trigger test backup
   kubectl apply -f <test-backup-cr.yaml>
   
   # Monitor backup job
   kubectl get jobs -n <namespace> -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to NFS/NAS**
   ```bash
   # Mount NFS/NAS storage
   # Update backup configuration to use NFS/NAS
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
   spec:
     backup:
       storages:
         nfs-backup:
           type: filesystem
           volume:
             persistentVolumeClaim:
               claimName: <nfs-pvc-name>
   '
   ```

2. **Restore MinIO from backup**
   ```bash
   # If MinIO data is corrupted, restore from backup
   # Restore MinIO data directory from backup
   # Restart MinIO pods
   kubectl delete pod -n minio-operator <minio-pod-name>
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 30-90 minutes

## Expected Data Loss

Risk only if outage spans retention window

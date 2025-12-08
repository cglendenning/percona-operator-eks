# MinIO Service Failure (Backup Target Unavailable) Recovery Process

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
read -p "Enter MinIO pod name: " MINIO_POD
read -p "Enter MinIO endpoint URL: " MINIO_ENDPOINT
read -p "Enter secondary MinIO endpoint URL: " SECONDARY_MINIO_ENDPOINT
read -p "Enter path to test backup CR YAML: " TEST_BACKUP_CR
```





## Primary Recovery Method

1. **Identify MinIO service failure**
   ```bash
   # Check MinIO pod status
   kubectl get pods -n minio-operator -l app=minio
   kubectl describe pod -n minio-operator <minio-pod-name>
   
   # Check MinIO logs
   kubectl logs -n minio-operator <minio-pod-name> --tail=100
   
   # Check backup job errors
   kubectl get jobs -n ${NAMESPACE} | grep backup
   kubectl logs -n ${NAMESPACE} <backup-job-pod> --tail=100
   ```

2. **Restart MinIO pods**
   ```bash
   # Restart MinIO StatefulSet
   kubectl rollout restart statefulset <minio-sts> -n minio-operator
   
   # Wait for pods to restart
   kubectl get pods -n minio-operator -w
   
   # Verify MinIO is healthy
   kubectl exec -n minio-operator ${MINIO_POD} -- mc admin info local
   ```

3. **Failover to secondary MinIO instance if available**
   ```bash
   # Check if secondary MinIO instance exists
   kubectl get pods -n minio-operator -l app=minio-secondary
   
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

4. **Buffer backups locally if MinIO unavailable**
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
   
   # Update backup configuration to use local storage temporarily
   kubectl edit perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME}
   ```

5. **Verify service is restored**
   ```bash
   # Test MinIO connectivity
   kubectl exec -n minio-operator ${MINIO_POD} -- mc ls local/${BUCKET_NAME}/
   
   # Trigger test backup
   kubectl apply -f ${TEST_BACKUP_CR}
   
   # Monitor backup job
   kubectl get jobs -n ${NAMESPACE} -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to NFS/NAS**
   ```bash
   # Mount NFS/NAS storage
   # Update backup configuration to use NFS/NAS
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
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

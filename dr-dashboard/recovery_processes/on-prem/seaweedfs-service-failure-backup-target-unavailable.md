# SeaweedFS Service Failure (Backup Target Unavailable) Recovery Process

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
read -p "Enter SeaweedFS filer namespace (e.g. seaweedfs-primary): " SEAWEEDFS_FILER_NS
read -p "Enter SeaweedFS S3 endpoint URL (e.g. http://seaweedfs-filer.seaweedfs-primary.svc:8333): " SEAWEEDFS_ENDPOINT
read -p "Enter secondary SeaweedFS endpoint URL: " SECONDARY_SEAWEEDFS_ENDPOINT
read -p "Enter path to test backup CR YAML: " TEST_BACKUP_CR
# Optional: export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from backup secret for aws s3 commands
```





## Primary Recovery Method

1. **Identify SeaweedFS service failure**
   ```bash
   # Check SeaweedFS filer pod status
   kubectl get pods -n ${SEAWEEDFS_FILER_NS} -l app=seaweedfs,component=filer
   kubectl describe pod -n ${SEAWEEDFS_FILER_NS} <filer-pod-name>
   
   # Check SeaweedFS filer logs
   kubectl logs -n ${SEAWEEDFS_FILER_NS} <filer-pod-name> --tail=100
   
   # Check backup job errors
   kubectl get jobs -n ${NAMESPACE} | grep backup
   kubectl logs -n ${NAMESPACE} <backup-job-pod> --tail=100
   ```

2. **Restart SeaweedFS filer pods**
   ```bash
   # Restart SeaweedFS filer deployment/statefulset
   kubectl rollout restart deployment -n ${SEAWEEDFS_FILER_NS} -l app=seaweedfs,component=filer
   # Or: kubectl rollout restart statefulset <seaweedfs-filer-sts> -n ${SEAWEEDFS_FILER_NS}
   
   kubectl get pods -n ${SEAWEEDFS_FILER_NS} -w
   
   # Verify SeaweedFS S3 connectivity (requires credentials from backup secret)
   aws s3 ls s3://${BUCKET_NAME}/ --endpoint-url ${SEAWEEDFS_ENDPOINT}
   ```

3. **Failover to secondary SeaweedFS instance if available**
   ```bash
   # Check if secondary SeaweedFS instance exists
   kubectl get pods -n ${SEAWEEDFS_FILER_NS} -l app=seaweedfs
   
   # Update backup configuration to point to secondary SeaweedFS
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         seaweedfs-backup:
           s3:
             endpointUrl: ${SECONDARY_SEAWEEDFS_ENDPOINT}
   '
   ```

4. **Buffer backups locally if SeaweedFS unavailable**
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
   # Test SeaweedFS S3 connectivity
   aws s3 ls s3://${BUCKET_NAME}/ --endpoint-url ${SEAWEEDFS_ENDPOINT}
   
   # Trigger test backup
   kubectl apply -f ${TEST_BACKUP_CR}
   kubectl get jobs -n ${NAMESPACE} -w
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to NFS/NAS**
   ```bash
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

2. **Restore SeaweedFS from backup**
   ```bash
   # If SeaweedFS data is corrupted, restore from backup
   # Restore SeaweedFS filer data directory from backup
   # Restart SeaweedFS filer pods
   kubectl delete pod -n ${SEAWEEDFS_FILER_NS} <filer-pod-name>
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 30-90 minutes

## Expected Data Loss

Risk only if outage spans retention window

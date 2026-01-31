# SeaweedFS Backup Target Unavailable (Regional Outage or ACL/Credential Issue) Recovery Process

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
read -p "Enter SeaweedFS S3 endpoint URL (e.g. http://seaweedfs-filer.seaweedfs-primary.svc:8333): " SEAWEEDFS_ENDPOINT
read -p "Enter secondary SeaweedFS endpoint URL: " SECONDARY_SEAWEEDFS_ENDPOINT
read -p "Enter credentials secret name: " SECRET_NAME
read -p "Enter backup deployment name: " BACKUP_DEPLOYMENT
read -p "Enter path to test backup CR YAML: " TEST_BACKUP_CR
# Export credentials from secret for aws s3 commands (if testing from host)
# export AWS_ACCESS_KEY_ID=$(kubectl get secret -n ${NAMESPACE} ${SECRET_NAME} -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
# export AWS_SECRET_ACCESS_KEY=$(kubectl get secret -n ${NAMESPACE} ${SECRET_NAME} -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
```





## Primary Recovery Method

Buffer locally; failover to secondary SeaweedFS instance; rotate credentials

### Steps

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n ${NAMESPACE} ${BACKUP_POD} --tail=100
   
   # Test SeaweedFS S3 connectivity (requires AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY from secret)
   aws s3 ls s3://${BUCKET_NAME}/ --endpoint-url ${SEAWEEDFS_ENDPOINT} 2>&1
   
   # Check backup credentials secret
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

3. **Failover to secondary SeaweedFS instance if available**
   ```bash
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

4. **Rotate SeaweedFS S3 credentials if credential issue**
   ```bash
   # SeaweedFS S3 credentials are configured in the filer (s3.config or weed shell s3.configure).
   # After updating credentials in SeaweedFS, create/update the Kubernetes secret:
   read -p "Enter new S3 access key: " NEW_ACCESS_KEY
   read -sp "Enter new S3 secret key: " NEW_SECRET_KEY; echo
   kubectl create secret generic seaweedfs-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=${NEW_ACCESS_KEY} \
     --from-literal=AWS_SECRET_ACCESS_KEY=${NEW_SECRET_KEY} \
     -n ${NAMESPACE} \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment ${BACKUP_DEPLOYMENT} -n ${NAMESPACE}
   ```

5. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl get perconaxtradbclusterbackup -n ${NAMESPACE}
   kubectl apply -f ${TEST_BACKUP_CR}
   kubectl get jobs -n ${NAMESPACE} -w
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to secondary DC object store/NAS**
   ```bash
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         seaweedfs-secondary:
           type: s3
           s3:
             bucket: ${SECONDARY_BUCKET_NAME}
             endpointUrl: ${SECONDARY_SEAWEEDFS_ENDPOINT}
             region: us-east-1
   '
   ```

2. **Verify service is restored**
   ```bash
   kubectl apply -f ${TEST_BACKUP_CR}
   # Verify backup completes successfully
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 1-3 hours

## Expected Data Loss

Risk only if outage spans retention window

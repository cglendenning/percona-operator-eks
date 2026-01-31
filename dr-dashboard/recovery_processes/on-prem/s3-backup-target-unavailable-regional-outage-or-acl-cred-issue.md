# S3 Backup Target Unavailable (Regional Outage or ACL/Credential Issue) Recovery Process

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
read -p "Enter SeaweedFS S3 endpoint URL (e.g. http://seaweedfs-filer.seaweedfs-primary.svc:8333): " SEAWEEDFS_ENDPOINT
read -p "Enter credentials secret name: " SECRET_NAME
read -p "Enter secondary SeaweedFS endpoint URL: " SECONDARY_SEAWEEDFS_ENDPOINT
read -p "Enter backup deployment name: " BACKUP_DEPLOYMENT
read -p "Enter new S3 access key (for credential rotation): " NEW_ACCESS_KEY
read -sp "Enter new S3 secret key: " NEW_SECRET_KEY; echo
# Export credentials from secret for aws s3: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
```





## Primary Recovery Method
Buffer locally; failover to secondary SeaweedFS instance; rotate credentials

### Steps

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n percona ${BACKUP_POD} --tail=100
   
   # Test SeaweedFS S3 connectivity
   aws s3 ls s3://${BUCKET_NAME}/ --endpoint-url ${SEAWEEDFS_ENDPOINT} 2>&1
   
   # Check backup credentials secret
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

3. **If credential issue: Rotate SeaweedFS S3 credentials**
   ```bash
   # Update credentials in SeaweedFS (s3.config or weed shell s3.configure). Then update Kubernetes secret:
   kubectl create secret generic seaweedfs-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=${NEW_ACCESS_KEY} \
     --from-literal=AWS_SECRET_ACCESS_KEY=${NEW_SECRET_KEY} \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment ${BACKUP_DEPLOYMENT} -n percona
   ```

4. **If SeaweedFS service issue: Restart or failover**
   ```bash
   # Check SeaweedFS filer pod status
   kubectl get pods -n seaweedfs-primary -l app=seaweedfs,component=filer
   
   # Restart SeaweedFS filer if needed
   kubectl rollout restart deployment -n seaweedfs-primary -l app=seaweedfs,component=filer
   
   # Or failover to secondary SeaweedFS instance if available
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n percona --type=merge -p '
   spec:
     backup:
       storages:
         seaweedfs-backup:
           s3:
             endpointUrl: ${SECONDARY_SEAWEEDFS_ENDPOINT}
   '
   ```

5. **If bucket issue: Fix bucket**
   ```bash
   # List buckets to verify connectivity
   aws s3 ls --endpoint-url ${SEAWEEDFS_ENDPOINT}
   
   # Create bucket if missing
   aws s3 mb s3://${BUCKET_NAME} --endpoint-url ${SEAWEEDFS_ENDPOINT}
   ```

6. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl get jobs -n percona -w
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method
Temporarily write backups to secondary DC object store/NAS

### Steps

1. **Set up alternative storage**
   - SeaweedFS in secondary DC
   - NFS/NAS storage
   - On-premises object storage

2. **Configure backup to alternative target**
   ```bash
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n percona --type=merge -p '
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

3. **Verify service is restored**
   ```bash
   # Trigger test backup and verify completion
   ```

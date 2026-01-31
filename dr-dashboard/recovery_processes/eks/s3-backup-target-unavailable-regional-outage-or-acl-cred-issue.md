# S3 Backup Target Unavailable Recovery Process

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
read -p "Enter S3 credentials secret name: " SECRET_NAME
read -p "Enter secondary AWS region: " SECONDARY_REGION
read -p "Enter SeaweedFS S3 endpoint URL (e.g. http://seaweedfs-filer.seaweedfs-primary.svc:8333): " SEAWEEDFS_ENDPOINT
read -p "Enter backup IAM user name: " BACKUP_USER
read -p "Enter backup deployment name: " BACKUP_DEPLOYMENT
read -p "Enter new AWS access key ID: " NEW_ACCESS_KEY
read -sp "Enter new AWS secret key: " NEW_SECRET_KEY; echo
```





## Primary Recovery Method
Buffer locally; failover to secondary S3 bucket; rotate IAM credentials

### Steps

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n percona ${BACKUP_POD} --tail=100
   
   # Test S3 connectivity
   kubectl exec -n percona ${BACKUP_POD} -- aws s3 ls s3://${BUCKET_NAME}/ 2>&1
   
   # Check IAM credentials
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

3. **If credential issue: Rotate IAM credentials**
   ```bash
   # Create new IAM access keys
   aws iam create-access-key --user-name ${BACKUP_USER}
   
   # Update Kubernetes secret
   kubectl create secret generic s3-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=${NEW_ACCESS_KEY} \
     --from-literal=AWS_SECRET_ACCESS_KEY=${NEW_SECRET_KEY} \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment ${BACKUP_DEPLOYMENT} -n percona
   ```

4. **If regional outage: Failover to secondary bucket**
   ```bash
   # Update backup configuration to secondary bucket/region
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n percona --type=merge -p '
   spec:
     backup:
       storages:
         s3:
           bucket: ${SECONDARY_BUCKET_NAME}
           region: ${SECONDARY_REGION}
   '
   ```

5. **If ACL issue: Fix bucket permissions**
   ```bash
   # Check bucket policy
   aws s3api get-bucket-policy --bucket ${BUCKET_NAME}
   
   # Update bucket policy to allow backup IAM user
   aws s3api put-bucket-policy --bucket ${BUCKET_NAME} --policy file://bucket-policy.json
   
   # Verify permissions
   aws s3api head-bucket --bucket ${BUCKET_NAME}
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
   - SeaweedFS in secondary DC
   - NFS/NAS storage
   - On-premises object storage

2. **Configure backup to alternative target**
   ```bash
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n percona --type=merge -p '
   spec:
     backup:
       storages:
         s3-compatible:
           bucket: ${SECONDARY_BUCKET_NAME}
           endpointUrl: ${SEAWEEDFS_ENDPOINT}
           region: us-east-1
   '
   ```

3. **Verify service is restored**
   ```bash
   # Trigger test backup
   kubectl exec -n percona ${BACKUP_POD} -- xtrabackup --backup --target-dir=/tmp/test-backup
   
   # Verify backup completes successfully
   ```

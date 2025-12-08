# S3 Service Failure (Backup Target Unavailable) Recovery Process

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
read -p "Enter AWS region [us-east-1]: " AWS_REGION; AWS_REGION=${AWS_REGION:-us-east-1}
read -p "Enter secondary AWS region: " SECONDARY_REGION
read -p "Enter path to test backup CR YAML: " TEST_BACKUP_CR
```





## Primary Recovery Method

1. **Identify S3 service failure**
   ```bash
   # Check backup job errors
   kubectl get jobs -n ${NAMESPACE} | grep backup
   kubectl logs -n ${NAMESPACE} <backup-job-pod> --tail=100
   
   # Check AWS service health
   aws s3 ls s3://<backup-bucket>/ --region ${AWS_REGION}
   
   # Check IAM credentials
   aws sts get-caller-identity
   ```

2. **Failover to secondary S3 bucket/region**
   ```bash
   # Check if secondary S3 bucket exists
   aws s3 ls s3://<secondary-backup-bucket>/ --region ${SECONDARY_REGION}
   
   # Update backup configuration to point to secondary S3 bucket
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         s3:
           s3:
             bucket: <secondary-backup-bucket>
             region: ${SECONDARY_REGION}
   '
   ```

3. **Buffer backups locally**
   ```bash
   # Create EBS volume for temporary backup storage
   # Or use existing EBS volumes
   # Update backup configuration to use local storage temporarily
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         local-backup:
           type: filesystem
           volume:
             persistentVolumeClaim:
               claimName: <ebs-pvc-name>
   '
   ```

4. **Check AWS service health**
   ```bash
   # Check AWS Service Health Dashboard
   # Verify S3 service status in affected region
   # Check for AWS service announcements
   ```

5. **Verify service is restored**
   ```bash
   # Test S3 connectivity
   aws s3 ls s3://<backup-bucket>/ --region ${AWS_REGION}
   
   # Trigger test backup
   kubectl apply -f ${TEST_BACKUP_CR}
   
   # Monitor backup job
   kubectl get jobs -n ${NAMESPACE} -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to EBS volumes**
   ```bash
   # Create EBS volume for backup storage
   # Create PVC pointing to EBS volume
   kubectl apply -f <ebs-pvc.yaml>
   
   # Update backup configuration
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         ebs-backup:
           type: filesystem
           volume:
             persistentVolumeClaim:
               claimName: <ebs-pvc-name>
   '
   ```

2. **Restore S3 access when available**
   ```bash
   # Once S3 service is restored, switch back to S3
   kubectl patch perconaxtradbcluster ${CLUSTER_NAME} -n ${NAMESPACE} --type=merge -p '
   spec:
     backup:
       storages:
         s3:
           s3:
             bucket: <backup-bucket>
             region: ${AWS_REGION}
   '
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 30-90 minutes

## Expected Data Loss

Risk only if outage spans retention window

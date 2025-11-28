# S3 Service Failure (Backup Target Unavailable) Recovery Process

## Primary Recovery Method

1. **Identify S3 service failure**
   ```bash
   # Check backup job errors
   kubectl get jobs -n <namespace> | grep backup
   kubectl logs -n <namespace> <backup-job-pod> --tail=100
   
   # Check AWS service health
   aws s3 ls s3://<backup-bucket>/ --region <region>
   
   # Check IAM credentials
   aws sts get-caller-identity
   ```

2. **Failover to secondary S3 bucket/region**
   ```bash
   # Check if secondary S3 bucket exists
   aws s3 ls s3://<secondary-backup-bucket>/ --region <secondary-region>
   
   # Update backup configuration to point to secondary S3 bucket
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
   spec:
     backup:
       storages:
         s3:
           s3:
             bucket: <secondary-backup-bucket>
             region: <secondary-region>
   '
   ```

3. **Buffer backups locally**
   ```bash
   # Create EBS volume for temporary backup storage
   # Or use existing EBS volumes
   # Update backup configuration to use local storage temporarily
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
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
   aws s3 ls s3://<backup-bucket>/ --region <region>
   
   # Trigger test backup
   kubectl apply -f <test-backup-cr.yaml>
   
   # Monitor backup job
   kubectl get jobs -n <namespace> -w
   
   # Verify backup completes successfully
   ```

## Alternate/Fallback Method

1. **Temporarily write backups to EBS volumes**
   ```bash
   # Create EBS volume for backup storage
   # Create PVC pointing to EBS volume
   kubectl apply -f <ebs-pvc.yaml>
   
   # Update backup configuration
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
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
   kubectl patch perconaxtradbcluster <cluster-name> -n <namespace> --type=merge -p '
   spec:
     backup:
       storages:
         s3:
           s3:
             bucket: <backup-bucket>
             region: <region>
   '
   ```

## Recovery Targets

- **Restore Time Objective**: 0 (no runtime failover)
- **Recovery Point Objective**: N/A (runtime unaffected)
- **Full Repair Time Objective**: 30-90 minutes

## Expected Data Loss

Risk only if outage spans retention window

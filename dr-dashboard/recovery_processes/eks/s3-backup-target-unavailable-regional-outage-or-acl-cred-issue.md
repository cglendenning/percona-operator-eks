# S3 Backup Target Unavailable Recovery Process

## Scenario
S3 backup target unavailable (regional outage or ACL/credential issue)

## Detection Signals
- PBM/xtrabackup errors in logs
- HTTP 5xx errors from S3
- IAM access denied errors
- Backup job failures
- CloudWatch/monitoring alerts for S3
- AWS service health dashboard showing issues

## Primary Recovery Method
Buffer locally; failover to secondary S3 bucket; rotate IAM credentials

### Steps

1. **Identify the root cause**
   ```bash
   # Check backup pod logs
   kubectl logs -n percona <backup-pod> --tail=100
   
   # Test S3 connectivity
   kubectl exec -n percona <backup-pod> -- aws s3 ls s3://<bucket-name>/ 2>&1
   
   # Check IAM credentials
   kubectl get secret -n percona <s3-secret> -o yaml
   ```

2. **Determine issue type**
   
   **Network/Regional Issue:**
   - Check AWS Service Health Dashboard
   - Test from another region
   
   **Credential Issue:**
   - Verify IAM user/role exists
   - Check IAM policy permissions
   - Test credentials manually
   
   **ACL/Bucket Policy:**
   - Verify bucket exists
   - Check bucket policy and ACLs

3. **Immediate action: Buffer backups locally**
   ```bash
   # Configure backup to write to local PVC temporarily
   # Update backup configuration
   kubectl edit perconaxtradbcluster -n percona <cluster-name>
   
   # Or create PVC for temporary backup storage
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
   ```

4. **If credential issue: Rotate IAM credentials**
   ```bash
   # Create new IAM access keys
   aws iam create-access-key --user-name <backup-user>
   
   # Update Kubernetes secret
   kubectl create secret generic s3-credentials \
     --from-literal=AWS_ACCESS_KEY_ID=<new-key> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<new-secret> \
     -n percona \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Restart backup pods to pick up new credentials
   kubectl rollout restart deployment <backup-deployment> -n percona
   ```

5. **If regional outage: Failover to secondary bucket**
   ```bash
   # Update backup configuration to secondary bucket/region
   kubectl patch perconaxtradbcluster <cluster-name> -n percona --type=merge -p '
   spec:
     backup:
       storages:
         s3:
           bucket: <secondary-bucket-name>
           region: <secondary-region>
   '
   ```

6. **If ACL issue: Fix bucket permissions**
   ```bash
   # Check bucket policy
   aws s3api get-bucket-policy --bucket <bucket-name>
   
   # Update bucket policy to allow backup IAM user
   aws s3api put-bucket-policy --bucket <bucket-name> --policy file://bucket-policy.json
   
   # Verify permissions
   aws s3api head-bucket --bucket <bucket-name>
   ```

7. **Verify backups can proceed**
   ```bash
   # Trigger test backup
   kubectl exec -n percona <backup-pod> -- xtrabackup --backup --target-dir=/tmp/test-backup
   
   # Monitor backup job
   kubectl get jobs -n percona -w
   ```

8. **Monitor S3 service recovery**
   - Check AWS Service Health Dashboard
   - Set up alerts for when primary bucket is accessible again
   - Plan migration back to primary bucket

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
         s3-compatible:
           bucket: <alternative-bucket>
           endpointUrl: https://<minio-endpoint>
           region: us-east-1
   '
   ```

3. **Sync backups when S3 recovers**
   ```bash
   # Copy backups from alternative storage to S3
   aws s3 sync /path/to/alternative/backups s3://<primary-bucket>/backups/
   ```

## Recovery Targets
- **RTO**: 0 (no runtime failover)
- **RPO**: N/A (runtime unaffected)
- **MTTR**: 1-3 hours

## Expected Data Loss
Risk only if outage spans retention window

## Affected Components
- Backup jobs
- S3 bucket
- IAM credentials/policies
- Backup schedules
- Cross-region replication

## Assumptions & Prerequisites
- Cross-region bucket replication enabled
- Secondary backup location available
- IAM credentials can be rotated quickly
- Backup retention window > typical outage duration
- Periodic restore tests prove viability

## Verification Steps

1. **Test backup creation**
   ```bash
   # Run manual backup
   kubectl create job --from=cronjob/<backup-cronjob> test-backup-$(date +%s) -n percona
   
   # Watch job completion
   kubectl wait --for=condition=complete job/test-backup-* -n percona --timeout=60m
   ```

2. **Verify backup in S3**
   ```bash
   # List recent backups
   aws s3 ls s3://<bucket-name>/backups/ --recursive | tail -10
   
   # Check backup size
   aws s3 ls s3://<bucket-name>/backups/<latest-backup>/ --recursive --human-readable
   ```

3. **Test restore from backup**
   ```bash
   # Download backup
   aws s3 cp s3://<bucket-name>/backups/<backup-name>/ /tmp/restore-test/ --recursive
   
   # Verify integrity
   xtrabackup --prepare --target-dir=/tmp/restore-test
   ```

4. **Check automated backups resume**
   ```bash
   # Check CronJob schedule
   kubectl get cronjobs -n percona
   
   # View recent backup jobs
   kubectl get jobs -n percona --sort-by=.metadata.creationTimestamp
   ```

## Rollback Procedure
If failover to secondary bucket fails:
1. Revert to primary bucket configuration
2. Use local buffered backups
3. Consider pausing automated backups until resolved
4. Focus on ensuring current DB stability (backups can catch up)

## Post-Recovery Actions

1. **Analyze root cause**
   - Was it preventable?
   - AWS service issue or configuration?
   - Document for future reference

2. **Improve resilience**
   - Enable cross-region replication
   - Set up secondary bucket in different region
   - Implement bucket versioning
   - Configure lifecycle policies

3. **Enhance monitoring**
   - Alert on S3 API errors
   - Monitor IAM credential age
   - Track backup success rate
   - Alert on backup duration increases

4. **Update runbooks**
   - Document actual recovery time
   - Update credential rotation procedure
   - Add troubleshooting steps learned

5. **Test restore procedures**
   - Schedule regular restore drills
   - Verify backups from all storage locations
   - Test failover to secondary bucket

6. **Review retention policies**
   - Ensure retention covers typical outage windows
   - Consider longer retention for critical backups
   - Implement immutable backups for ransomware protection

## Related Scenarios
- Backups complete but non-restorable
- Credential compromise
- Primary DC power/cooling outage
- Ransomware attack (if S3 compromised)

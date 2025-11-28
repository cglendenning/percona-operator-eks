# Storage PVC Corruption Recovery Process

## Primary Recovery Method
Remove failed node; recreate pod; let PXC SST/IST re-seed from peers

### Steps

1. **Identify the affected pod and PVC**
   ```bash
   kubectl get pods -n <namespace>
   kubectl describe pod -n <namespace> <pod-name>
   kubectl get pvc -n <namespace>
   ```

2. **Scale down the StatefulSet to remove the corrupted pod**
   ```bash
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=<n-1>
   ```

3. **CRITICAL: Ensure cluster maintains quorum (need majority of nodes up)**

4. **Delete the corrupted PVC**
   ```bash
   kubectl delete pvc <pvc-name> -n <namespace>
   ```

5. **Scale StatefulSet back up**
   ```bash
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=<n>
   ```

6. **Monitor pod creation and storage provisioning**
   ```bash
   kubectl get pods -n <namespace> -w
   kubectl get pvc -n <namespace> -w
   ```

7. **Watch for IST (Incremental State Transfer) or SST (State Snapshot Transfer)**
   ```bash
   kubectl logs -n <namespace> <pod-name> -f
   ```

8. **Verify service is restored**
   ```bash
   # Verify node rejoins and syncs
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Restore individual table/DB from S3 physical backup to side instance and logical import

### Steps

1. **Restore latest backup to a temporary instance**
   ```bash
   # Download backup from S3
   aws s3 sync s3://<backup-bucket>/backups/<backup-name>/ /tmp/restore/
   
   # Use Percona XtraBackup
   xtrabackup --prepare --target-dir=/tmp/restore
   xtrabackup --copy-back --target-dir=/tmp/restore --datadir=/tmp/restore-mysql
   ```

2. **Export specific tables/databases**
   ```bash
   mysqldump -u root -p <database> <table> > restore.sql
   ```

3. **Import to production cluster**
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -u root -p <database> < restore.sql
   ```

4. **Verify service is restored**
   ```bash
   # Verify data integrity
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Test write operations from application
   ```

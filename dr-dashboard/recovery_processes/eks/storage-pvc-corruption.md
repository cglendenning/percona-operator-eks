# Storage PVC Corruption Recovery Process

## Scenario
Storage PVC corruption for a single PXC node

## Detection Signals
- InnoDB corruption errors in logs
- fsck errors
- PXC node unable to start or continuously desyncs
- Pod stuck in CrashLoopBackOff with storage-related errors
- MySQL error logs showing corrupted tables

## Primary Recovery Method
Remove failed node; recreate pod; let PXC SST/IST re-seed from peers

### Steps
1. Identify the affected pod and PVC
   ```bash
   kubectl get pods -n <namespace>
   kubectl describe pod -n <namespace> <pod-name>
   kubectl get pvc -n <namespace>
   ```

2. Scale down the StatefulSet to remove the corrupted pod
   ```bash
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=<n-1>
   ```

3. Delete the corrupted PVC
   ```bash
   kubectl delete pvc <pvc-name> -n <namespace>
   ```

4. **CRITICAL**: Ensure cluster maintains quorum (need majority of nodes up)

5. Scale StatefulSet back up
   ```bash
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=<n>
   ```

6. Monitor pod creation and storage provisioning
   ```bash
   kubectl get pods -n <namespace> -w
   kubectl get pvc -n <namespace> -w
   ```

7. Watch for IST (Incremental State Transfer) or SST (State Snapshot Transfer)
   ```bash
   kubectl logs -n <namespace> <pod-name> -f
   ```

8. Verify node rejoins and syncs
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep%';"
   ```

## Alternate/Fallback Method
Restore individual table/DB from S3 physical backup to side instance and logical import

### Steps
1. If the entire cluster is affected or IST/SST fails, restore from backup

2. Restore latest backup to a temporary instance
   ```bash
   # Use Percona XtraBackup or your backup solution
   xtrabackup --copy-back --target-dir=<backup-path>
   ```

3. Export specific tables/databases
   ```bash
   mysqldump -u root -p <database> <table> > restore.sql
   ```

4. Import to production cluster
   ```bash
   mysql -u root -p <database> < restore.sql
   ```

5. Verify data integrity and consistency

## Recovery Targets
- **RTO**: 1-3 hours
- **RPO**: 0-5 minutes (IST window)
- **MTTR**: 2-6 hours

## Expected Data Loss
None to seconds (if IST fails then SST, still no loss)

## Affected Components
- PersistentVolume for specific pod
- Underlying storage (EBS volume, VMware datastore, etc.)
- File system layer

## Assumptions & Prerequisites
- Cluster remains quorate (>50% nodes healthy)
- IST preferred over SST for faster recovery
- SST uses donor node - ensure donor has capacity
- Adequate network bandwidth for SST
- StorageClass supports dynamic provisioning
- Backups are regularly tested and verified

## Verification Steps
1. Check cluster status and size
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

2. Verify all nodes are synced
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
   ```

3. Check for InnoDB errors
   ```bash
   kubectl logs -n <namespace> <pod-name> | grep -i error
   ```

4. Run integrity checks on critical tables
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "CHECK TABLE <database>.<table>;"
   ```

5. Monitor replication lag and cluster metrics in PMM

## Rollback Procedure
If recreation fails:
1. Keep cluster running with reduced capacity (n-1 nodes)
2. Schedule maintenance window for full investigation
3. Consider restoring entire cluster from backup if corruption spreads

## Related Scenarios
- Single MySQL pod failure
- Cluster loses quorum
- Widespread data corruption
- S3 backup target unavailable

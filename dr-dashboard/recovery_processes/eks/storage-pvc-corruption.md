# Storage PVC Corruption Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -p "Enter StatefulSet name: " STS_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter PVC name: " PVC_NAME
```





## Primary Recovery Method
Remove failed node; recreate pod; let PXC SST/IST re-seed from peers

### Steps

1. **Identify the affected pod and PVC**
   ```bash
   kubectl get pods -n ${NAMESPACE}
   kubectl describe pod -n ${NAMESPACE} ${POD_NAME}
   kubectl get pvc -n ${NAMESPACE}
   ```

2. **Scale down the StatefulSet to remove the corrupted pod**
   ```bash
   kubectl scale statefulset ${STS_NAME} -n ${NAMESPACE} --replicas=<n-1>
   ```

3. **CRITICAL: Ensure cluster maintains quorum (need majority of nodes up)**

4. **Delete the corrupted PVC**
   ```bash
   kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE}
   ```

5. **Scale StatefulSet back up**
   ```bash
   kubectl scale statefulset ${STS_NAME} -n ${NAMESPACE} --replicas=<n>
   ```

6. **Monitor pod creation and storage provisioning**
   ```bash
   kubectl get pods -n ${NAMESPACE} -w
   kubectl get pvc -n ${NAMESPACE} -w
   ```

7. **Watch for IST (Incremental State Transfer) or SST (State Snapshot Transfer)**
   ```bash
   kubectl logs -n ${NAMESPACE} ${POD_NAME} -f
   ```

8. **Verify service is restored**
   ```bash
   # Verify node rejoins and syncs
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
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
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -u root -p <database> < restore.sql
   ```

4. **Verify service is restored**
   ```bash
   # Verify data integrity
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT COUNT(*) FROM <database>.<table>;"
   
   # Test write operations from application
   ```

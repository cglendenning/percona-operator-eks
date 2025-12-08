# Cluster Loses Quorum Recovery Process

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
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -p "Enter StatefulSet name: " STS_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter secondary DC kubectl context: " SECONDARY_CONTEXT
```





## Primary Recovery Method
Recover majority; bootstrap from most advanced node; follow Percona PXC bootstrap runbook

### Steps

⚠️ **CRITICAL**: This is a high-risk procedure. Do NOT proceed without senior DBA approval.

1. **Assess the situation**
   ```bash
   kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=pxc
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep%';" || echo "Node unavailable"
   ```

2. **Find the most advanced node (highest seqno)**
   
   For each available node, check:
   ```bash
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- cat /var/lib/mysql/grastate.dat
   ```
   
   Look for the node with the highest `seqno`. If seqno is -1, check:
   ```bash
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysqld --wsrep-recover
   ```

3. **Bootstrap from the most advanced node**
   
   Option A: Using Percona Operator (if working):
   ```bash
   kubectl edit perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME}
   # Set spec.pxc.allowUnsafeConfigurations: true
   # Or patch specific pod to bootstrap
   ```

   Option B: Manual bootstrap (if operator is not working):
   ```bash
   # Scale down to just the bootstrap node
   kubectl scale statefulset ${STS_NAME} -n ${NAMESPACE} --replicas=1
   
   # Exec into the bootstrap pod
   kubectl exec -it -n ${NAMESPACE} ${POD_NAME} -- bash
   
   # Edit MySQL config to bootstrap
   echo "[mysqld]" >> /etc/mysql/my.cnf
   echo "wsrep_new_cluster" >> /etc/mysql/my.cnf
   
   # Restart MySQL (within container)
   supervisorctl restart mysql
   
   # Verify it's now Primary
   mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

4. **Join other nodes one by one**
   ```bash
   # Remove bootstrap flag
   kubectl exec -it -n ${NAMESPACE} ${POD_NAME} -- bash
   # Remove wsrep_new_cluster from my.cnf
   
   # Scale up gradually
   kubectl scale statefulset ${STS_NAME} -n ${NAMESPACE} --replicas=2
   # Wait and verify
   kubectl scale statefulset ${STS_NAME} -n ${NAMESPACE} --replicas=3
   ```

5. **Verify service is restored**
   ```bash
   # Verify cluster reformation
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"  # Should be Primary
   
   # Test writes
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS test; USE test; CREATE TABLE IF NOT EXISTS recovery_test (id INT, ts TIMESTAMP); INSERT INTO recovery_test VALUES (1, NOW());"
   ```

## Alternate/Fallback Method
Promote secondary DC replica to primary; redirect traffic

### Steps

1. **Activate DR plan**
   - Verify secondary DC replica is healthy and up-to-date
   - Promote secondary to primary (DNS/ingress cutover)
   - Update application configuration to point to new primary

2. **Verify service is restored**
   ```bash
   # Test write operations on secondary DC
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   ```

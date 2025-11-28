# Cluster Loses Quorum Recovery Process

## Primary Recovery Method
Recover majority; bootstrap from most advanced node; follow Percona PXC bootstrap runbook

### Steps

⚠️ **CRITICAL**: This is a high-risk procedure. Do NOT proceed without senior DBA approval.

1. **Assess the situation**
   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=pxc
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep%';" || echo "Node unavailable"
   ```

2. **Find the most advanced node (highest seqno)**
   
   For each available node, check:
   ```bash
   kubectl exec -n <namespace> <pod-name> -- cat /var/lib/mysql/grastate.dat
   ```
   
   Look for the node with the highest `seqno`. If seqno is -1, check:
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysqld --wsrep-recover
   ```

3. **Bootstrap from the most advanced node**
   
   Option A: Using Percona Operator (if working):
   ```bash
   kubectl edit perconaxtradbcluster -n <namespace> <cluster-name>
   # Set spec.pxc.allowUnsafeConfigurations: true
   # Or patch specific pod to bootstrap
   ```

   Option B: Manual bootstrap (if operator is not working):
   ```bash
   # Scale down to just the bootstrap node
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=1
   
   # Exec into the bootstrap pod
   kubectl exec -it -n <namespace> <pod-name> -- bash
   
   # Edit MySQL config to bootstrap
   echo "[mysqld]" >> /etc/mysql/my.cnf
   echo "wsrep_new_cluster" >> /etc/mysql/my.cnf
   
   # Restart MySQL (within container)
   supervisorctl restart mysql
   
   # Verify it's now Primary
   mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

4. **Join other nodes one by one**
   ```bash
   # Remove bootstrap flag
   kubectl exec -it -n <namespace> <pod-0> -- bash
   # Remove wsrep_new_cluster from my.cnf
   
   # Scale up gradually
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=2
   # Wait and verify
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=3
   ```

5. **Verify service is restored**
   ```bash
   # Verify cluster reformation
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"  # Should be Primary
   
   # Test writes
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "CREATE DATABASE IF NOT EXISTS test; USE test; CREATE TABLE IF NOT EXISTS recovery_test (id INT, ts TIMESTAMP); INSERT INTO recovery_test VALUES (1, NOW());"
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
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   ```

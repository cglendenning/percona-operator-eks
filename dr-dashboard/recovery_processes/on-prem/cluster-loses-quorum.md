# Cluster Loses Quorum Recovery Process

## Scenario
Cluster loses quorum (multiple PXC pods down)

## Detection Signals
- Galera wsrep_cluster_status shows "non-Primary"
- No writes accepted (reads may still work)
- Application returning 500 errors or connection timeouts
- Multiple PXC pods down simultaneously
- wsrep_cluster_size shows less than majority

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

3. **Create a backup before proceeding**
   ```bash
   # If possible, take snapshots of all PVCs
   # Document current state
   kubectl get all -n <namespace> -o yaml > pre-bootstrap-state.yaml
   ```

4. **Bootstrap from the most advanced node**
   
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

5. **Join other nodes one by one**
   ```bash
   # Remove bootstrap flag
   kubectl exec -it -n <namespace> <pod-0> -- bash
   # Remove wsrep_new_cluster from my.cnf
   
   # Scale up gradually
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=2
   # Wait and verify
   kubectl scale statefulset <sts-name> -n <namespace> --replicas=3
   ```

6. **Verify cluster reformation**
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
   ```

## Alternate/Fallback Method
Promote secondary DC replica to primary; redirect traffic

### Steps
1. If primary cluster is completely lost, activate DR plan
2. Verify secondary DC replica is healthy and up-to-date
3. Promote secondary to primary (DNS/ingress cutover)
4. Update application configuration to point to new primary
5. Rebuild failed primary cluster from backups when ready

## Recovery Targets
- **RTO**: 30-90 minutes
- **RPO**: 0-60 seconds
- **MTTR**: 1-3 hours

## Expected Data Loss
None to <1 minute (unflushed transactions)

## Affected Components
- Multiple PXC pods
- Percona Operator
- HAProxy/ProxySQL
- Application write path

## Assumptions & Prerequisites
- At least one node has complete data (highest seqno)
- PVCs are intact and accessible
- You have emergency access to pods/containers
- Backups are available as last resort
- Change control approval for bootstrap operation
- Application can tolerate write downtime

## Verification Steps
1. All nodes show as "Primary"
   ```bash
   for i in 0 1 2; do
     kubectl exec -n <namespace> cluster-pxc-$i -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   done
   ```

2. Cluster size matches expected
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

3. All nodes are synced
   ```bash
   for i in 0 1 2; do
     kubectl exec -n <namespace> cluster-pxc-$i -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
   done
   ```

4. Test writes
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "CREATE DATABASE IF NOT EXISTS test; USE test; CREATE TABLE IF NOT EXISTS recovery_test (id INT, ts TIMESTAMP); INSERT INTO recovery_test VALUES (1, NOW());"
   ```

5. Verify data consistency across nodes

## Rollback Procedure
If bootstrap fails or causes data inconsistency:
1. Stop all MySQL instances
2. Restore all nodes from most recent verified backup
3. Rebuild cluster from scratch following installation procedure
4. Apply PITR if needed to recover recent transactions

## Post-Recovery Actions
1. Root cause analysis - why did quorum loss occur?
2. Review pod anti-affinity and topology spread constraints
3. Review PodDisruptionBudgets
4. Consider increasing cluster size (5 nodes for better fault tolerance)
5. Implement better monitoring and alerting for quorum status
6. Schedule backup restore drill to verify DR readiness

## Related Scenarios
- Kubernetes worker node failure
- Kubernetes control plane outage
- Primary DC power/cooling outage
- Ransomware attack

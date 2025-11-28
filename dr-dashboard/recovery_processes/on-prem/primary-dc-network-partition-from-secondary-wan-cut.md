# Primary DC Network Partition from Secondary (WAN Cut) Recovery Process

## Primary Recovery Method
Stay primary in current DC; queue async replication; monitor lag

### Steps

1. **Verify the partition**
   ```bash
   # Check replication status
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G"
   
   # Test network connectivity to secondary DC
   ping <secondary-dc-endpoint>
   traceroute <secondary-dc-endpoint>
   ```

2. **Confirm primary DC is healthy**
   ```bash
   kubectl get nodes
   kubectl get pods -n <namespace>
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

3. **Continue accepting writes in primary DC**
   - Application continues normal operation
   - Transactions are queued for replication
   - Monitor binlog accumulation

4. **When WAN connectivity is restored**
   ```bash
   # Verify replication resumes
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G"
   
   # Monitor catch-up progress
   watch -n 5 "kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind_Master"
   ```

5. **Verify service is restored**
   ```bash
   # Verify replication is caught up
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
If app tier in secondary is hot-standby, execute app failover if primary DC instability persists

### Steps

1. **Assess primary DC stability**
   - If primary DC is experiencing cascading failures
   - If partition is due to primary DC network issues
   - If prolonged outage is expected

2. **Prepare secondary DC for promotion**
   ```bash
   # Verify secondary DC health
   kubectl --context=secondary-dc get pods -n percona
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT 1;"
   ```

3. **Stop writes to primary**
   - Put application in read-only mode
   - Drain in-flight transactions

4. **Promote secondary to primary**
   ```bash
   # Stop replication on secondary
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "STOP SLAVE; RESET SLAVE ALL;"
   
   # Update DNS/ingress to point to secondary DC
   # Reconfigure application to use secondary
   # Enable writes on secondary
   ```

5. **Verify service is restored**
   ```bash
   # Test write operations on secondary DC
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
   # Verify application connectivity
   ```

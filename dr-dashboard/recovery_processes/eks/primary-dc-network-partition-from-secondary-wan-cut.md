# Primary DC Network Partition from Secondary (WAN Cut) Recovery Process

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
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter secondary DC kubectl context: " SECONDARY_CONTEXT
```





## Primary Recovery Method
Stay primary in current DC; queue async replication; monitor lag

### Steps

1. **Verify the partition**
   ```bash
   # Check replication status
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G"
   
   # Test network connectivity to secondary DC
   ping <secondary-dc-endpoint>
   traceroute <secondary-dc-endpoint>
   ```

2. **Confirm primary DC is healthy**
   ```bash
   kubectl get nodes
   kubectl get pods -n ${NAMESPACE}
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

3. **Continue accepting writes in primary DC**
   - Application continues normal operation
   - Transactions are queued for replication
   - Monitor binlog accumulation

4. **When WAN connectivity is restored**
   ```bash
   # Verify replication resumes
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G"
   
   # Monitor catch-up progress
   watch -n 5 "kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind_Master"
   ```

5. **Verify service is restored**
   ```bash
   # Verify replication is caught up
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   
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
   kubectl --context=${SECONDARY_CONTEXT} get pods -n percona
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   ```

3. **Stop writes to primary**
   - Put application in read-only mode
   - Drain in-flight transactions

4. **Promote secondary to primary**
   ```bash
   # Stop replication on secondary
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "STOP SLAVE; RESET SLAVE ALL;"
   
   # Update DNS/ingress to point to secondary DC
   # Reconfigure application to use secondary
   # Enable writes on secondary
   ```

5. **Verify service is restored**
   ```bash
   # Test write operations on secondary DC
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
   # Verify application connectivity
   ```

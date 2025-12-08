# Primary DC Power/Cooling Outage (Site Down) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter secondary DC kubectl context: " SECONDARY_CONTEXT
```





## Primary Recovery Method
Promote Secondary DC replica to primary (planned role swap)

### Steps

⚠️ **CRITICAL**: This is a major failover event requiring coordination

1. **Confirm primary DC is completely down**
   ```bash
   # From secondary DC or external location
   ping <primary-dc-nodes>
   kubectl --context=primary-dc cluster-info  # Should timeout
   ```

2. **Verify secondary DC is healthy**
   ```bash
   kubectl --context=${SECONDARY_CONTEXT} get nodes
   kubectl --context=${SECONDARY_CONTEXT} get pods -n percona
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   ```

3. **Check replication lag on secondary**
   ```bash
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

4. **Stop writes to primary (if any route still exists)**
   - Update DNS to point to secondary DC
   - Update load balancers
   - Notify application teams to pause deployments

5. **Promote secondary to primary**
   ```bash
   # Stop replication on secondary
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "STOP SLAVE;"
   
   # Reset slave status (make it standalone)
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "RESET SLAVE ALL;"
   
   # Verify it's writable
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW VARIABLES LIKE 'read_only';"
   ```

6. **Update DNS and ingress**
   - Update external DNS A records to point to secondary DC
   - Update ingress/load balancer configurations
   - Verify DNS propagation: `dig <your-db-endpoint>`

7. **Update application configuration**
   - Point applications to new primary endpoint
   - Restart application pods if needed
   - Verify write operations succeed

8. **Verify service is restored**
   ```bash
   # Test write operations
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
   # Verify application connectivity
   # Check application logs for successful DB connections
   ```

## Alternate/Fallback Method
Restore latest backup to Secondary if replica is stale/unhealthy

### Steps

1. **If secondary replica is too far behind or corrupted**
   - Restore latest backup to secondary DC from S3
   - Apply point-in-time recovery from binlogs
   - Verify data integrity
   - Promote to primary (follow steps 5-8 from Primary Recovery Method)

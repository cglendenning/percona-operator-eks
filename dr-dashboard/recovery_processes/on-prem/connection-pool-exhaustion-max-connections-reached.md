# Connection Pool Exhaustion (max_connections Reached) Recovery Process

## Primary Recovery Method

1. **Identify the connection issue**
   ```bash
   # Check current connection count
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'Threads_connected';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'Max_used_connections';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'max_connections';"
   
   # List all connections
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW PROCESSLIST;"
   
   # Count connections by user
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT USER, COUNT(*) as connections FROM information_schema.processlist GROUP BY USER;"
   ```

2. **Kill idle or long-running connections**
   ```bash
   # Find idle connections (sleeping for more than 60 seconds)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO, 50) as QUERY FROM information_schema.processlist WHERE COMMAND='Sleep' AND TIME > 60 ORDER BY TIME DESC;"
   
   # Kill idle connections (example: kill connections idle for more than 5 minutes)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT CONCAT('KILL ', ID, ';') FROM information_schema.processlist WHERE COMMAND='Sleep' AND TIME > 300 INTO OUTFILE '/tmp/kill_idle.sql';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SOURCE /tmp/kill_idle.sql;"
   
   # Or kill specific connection IDs
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "KILL <connection-id>;"
   ```

3. **Identify and address connection leaks**
   ```bash
   # Check for connections from specific applications/users
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT USER, HOST, COUNT(*) as conn_count FROM information_schema.processlist WHERE USER != 'system user' GROUP BY USER, HOST ORDER BY conn_count DESC;"
   
   # Check application connection pool configuration
   # Review application logs for connection pool errors
   # Verify application is properly closing connections
   ```

4. **Increase max_connections if needed**
   ```bash
   # Check current max_connections setting
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'max_connections';"
   
   # Temporarily increase max_connections (will reset on restart)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL max_connections = 500;"
   
   # For permanent change, update PerconaXtraDBCluster CR
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to add/update:
   # spec.pxc.configuration: |
   #   [mysqld]
   #   max_connections = 500
   kubectl apply -f cluster-backup.yaml
   ```

5. **Restart PXC pods to reset connection count (if necessary)**
   ```bash
   # Only if connections cannot be killed and max_connections cannot be increased
   # This will reset all connections but may cause brief service interruption
   kubectl delete pod -n <namespace> <pod-name>
   
   # Wait for pod to restart
   kubectl get pods -n <namespace> -w
   ```

6. **Verify connections are restored**
   ```bash
   # Check connection count is below max_connections
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'Threads_connected';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'max_connections';"
   
   # Test new connections can be established
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT 1;"
   
   # Monitor application logs for successful connections
   ```

## Alternate/Fallback Method

1. **Fix application connection pooling**
   ```bash
   # Identify applications with connection leaks
   # Review application connection pool settings
   # Ensure applications are using connection pooling correctly
   # Verify connection timeout settings
   ```

2. **Restart PXC pods to reset connection count**
   ```bash
   # Delete PXC pods one at a time (if cluster has quorum)
   kubectl delete pod -n <namespace> <pod-name>
   
   # Wait for pod to restart and rejoin cluster
   kubectl get pods -n <namespace> -w
   
   # Verify cluster health after restart
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

## Recovery Targets

- **Restore Time Objective**: 15 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 15-30 minutes

## Expected Data Loss

None

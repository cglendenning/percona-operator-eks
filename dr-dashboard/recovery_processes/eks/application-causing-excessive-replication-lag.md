# Application Causing Excessive Replication Lag Recovery Process

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
```





## Primary Recovery Method

1. **Identify replication lag and verify application is the cause**
   ```bash
   # Check replication lag
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   
   # Monitor replication lag over time
   watch -n 5 'kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master'
   
   # Verify primary cluster is operating normally
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   kubectl top pods -n ${NAMESPACE} | grep pxc
   
   # Check CloudWatch metrics for replication lag
   aws cloudwatch get-metric-statistics \
     --namespace MySQL \
     --metric-name ReplicationLag \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Average,Maximum
   
   # Check if lag occurs during predictable peak hours
   # Review replication lag metrics over time
   ```

2. **Identify slow queries or bulk operations on primary**
   ```bash
   # Check running queries on primary
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "SHOW PROCESSLIST;"
   
   # Check slow query log
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "SHOW VARIABLES LIKE 'slow_query_log%';"
   kubectl logs -n ${NAMESPACE} <primary-pod> | grep -i "slow query"
   
   # Identify problematic queries causing replication lag
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "SELECT sql_text, exec_count, avg_timer_wait/1000000000000 as avg_time_sec, sum_timer_wait/1000000000000 as total_time_sec FROM performance_schema.events_statements_summary_by_digest ORDER BY sum_timer_wait DESC LIMIT 10;"
   ```

3. **Optimize or throttle application queries**
   ```bash
   # Kill problematic queries if safe
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "KILL <query-id>;"
   
   # Set query timeout
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "SET GLOBAL max_execution_time = 30000;"
   
   # Throttle application connections
   # Update application connection pool settings
   # Reduce concurrent queries during peak hours
   ```

4. **Add read replicas or scale replication resources**
   ```bash
   # Scale up read replicas if available
   kubectl patch perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} --type=json -p='[
     {
       "op": "replace",
       "path": "/spec/pxc/size",
       "value": <new-size>
     }
   ]'
   
   # Increase replication thread resources
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SET GLOBAL slave_parallel_workers = 4;"
   
   # Increase replication buffer size
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SET GLOBAL slave_pending_jobs_size_max = 1073741824;"
   ```

5. **Verify replication lag is reduced and RPO is restored**
   ```bash
   # Check replication lag
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   
   # Verify replication is catching up
   watch -n 5 'kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master'
   
   # Verify RPO is within acceptable limits
   # Check that Seconds_Behind_Master is below RPO threshold
   ```

## Alternate/Fallback Method

1. **Temporarily block problematic application**
   ```bash
   # Identify application causing lag
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "SELECT USER, HOST, COUNT(*) FROM information_schema.PROCESSLIST WHERE USER != 'system' GROUP BY USER, HOST;"
   
   # Block application connections if safe
   kubectl exec -n ${NAMESPACE} <primary-pod> -- mysql -e "REVOKE ALL PRIVILEGES ON *.* FROM '<app-user>'@'<app-host>';"
   ```

2. **Enable read-only mode on replica**
   ```bash
   # Set replica to read-only
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SET GLOBAL read_only = ON;"
   ```

3. **Accept increased RPO if lag is acceptable**
   ```bash
   # If replication lag is within acceptable bounds for business
   # Document the RPO deviation
   # Plan for optimization during maintenance window
   # Monitor to ensure lag doesn't continue to increase
   ```

## Recovery Targets

- **Restore Time Objective**: 4 hours
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 2-8 hours

## Expected Data Loss

None (primary unaffected); RPO exceeded on secondary site (compliance/DR readiness impact)

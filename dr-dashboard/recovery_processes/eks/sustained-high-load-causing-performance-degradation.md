# Sustained High Load Causing Performance Degradation Recovery Process

## Primary Recovery Method

1. **Identify the performance issue**
   ```bash
   # Check CPU and memory usage
   kubectl top pods -n <namespace> | grep pxc
   
   # Check slow query log
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'slow_query_log';"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'long_query_time';"
   kubectl exec -n <namespace> <pod> -- tail -100 /var/lib/mysql/slow-query.log
   
   # Check current running queries
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO, 100) as QUERY FROM information_schema.processlist WHERE COMMAND != 'Sleep' ORDER BY TIME DESC;"
   
   # Check replication lag
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

2. **Scale up resources**
   ```bash
   # Check current resource limits
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml | grep -A 10 resources
   
   # Update PerconaXtraDBCluster CR to increase resources
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to increase:
   # spec.pxc.resources.requests.cpu
   # spec.pxc.resources.requests.memory
   # spec.pxc.resources.limits.cpu
   # spec.pxc.resources.limits.memory
   kubectl apply -f cluster-backup.yaml
   
   # Wait for pods to restart with new resources
   kubectl get pods -n <namespace> -w
   ```

3. **Optimize slow queries**
   ```bash
   # Identify slow queries
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT sql_text, exec_count, avg_timer_wait/1000000000000 as avg_time_sec, sum_timer_wait/1000000000000 as total_time_sec FROM performance_schema.events_statements_summary_by_digest ORDER BY sum_timer_wait DESC LIMIT 10;"
   
   # Check for missing indexes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, CARDINALITY FROM information_schema.STATISTICS WHERE TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys') ORDER BY CARDINALITY;"
   
   # Analyze and optimize queries
   # Use EXPLAIN to analyze query plans
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "EXPLAIN <problematic-query>;"
   ```

4. **Add read replicas if available**
   ```bash
   # Check current replica count
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml | grep replicas
   
   # Scale up replicas in PerconaXtraDBCluster CR
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to increase:
   # spec.pxc.size (if using PXC replicas)
   # Or configure read replicas if supported
   kubectl apply -f cluster-backup.yaml
   ```

5. **Implement query throttling**
   ```bash
   # Enable query throttling via PerconaXtraDBCluster CR
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to add:
   # spec.pxc.configuration: |
   #   [mysqld]
   #   max_connections = <appropriate-limit>
   #   thread_pool_size = <appropriate-size>
   kubectl apply -f cluster-backup.yaml
   
   # Or use ProxySQL/HAProxy to implement connection throttling
   ```

6. **Verify performance is restored**
   ```bash
   # Monitor resource usage
   kubectl top pods -n <namespace> | grep pxc
   
   # Check query response times
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT AVG(TIMER_WAIT)/1000000000000 as avg_time_sec FROM performance_schema.events_statements_summary_by_digest WHERE COUNT_STAR > 0;"
   
   # Test application response times
   # Monitor application metrics and logs
   ```

## Alternate/Fallback Method

1. **Enable read-only mode temporarily**
   ```bash
   # Set database to read-only (emergency measure)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL read_only = ON;"
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SET GLOBAL super_read_only = ON;"
   
   # This allows reads but blocks writes
   # Use only if writes can be temporarily suspended
   ```

2. **Failover to secondary DC if available**
   ```bash
   # If secondary DC has lower load, promote it to primary
   # Follow secondary DC promotion procedures
   # Update application connections to point to secondary DC
   ```

## Recovery Targets

- **Restore Time Objective**: 60 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 1-3 hours

## Expected Data Loss

None

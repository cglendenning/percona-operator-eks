# Increased API Call Volume Causes Performance Degradation Recovery Process

## Primary Recovery Method

1. **Identify performance degradation from increased API volume**
   ```bash
   # Check CPU and memory usage
   kubectl top pods -n <namespace> | grep -E 'pxc|haproxy'
   
   # Check current cluster size
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o jsonpath='{.spec.pxc.size}'
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o jsonpath='{.spec.haproxy.size}'
   
   # Check application metrics for API call volume
   # Review application logs and metrics dashboards
   # Verify increased API traffic is the root cause
   ```

2. **Scale up PXC cluster size**
   ```bash
   # Get current PerconaXtraDBCluster CR
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   
   # Edit cluster-backup.yaml to increase PXC size
   # Change: spec.pxc.size from current value (e.g., 3) to larger value (e.g., 5)
   # Example:
   # spec:
   #   pxc:
   #     size: 5
   
   # Apply the change
   kubectl apply -f cluster-backup.yaml
   
   # Monitor pod scaling
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=pxc -w
   
   # Wait for new pods to be ready and join cluster
   kubectl wait --for=condition=ready pod -n <namespace> -l app.kubernetes.io/component=pxc --timeout=600s
   ```

3. **Scale up HAProxy size if needed**
   ```bash
   # If HAProxy is the bottleneck, scale it up
   # Edit cluster-backup.yaml to increase HAProxy size
   # Change: spec.haproxy.size from current value to larger value
   # Example:
   # spec:
   #   haproxy:
   #     size: 3
   
   # Apply the change
   kubectl apply -f cluster-backup.yaml
   
   # Monitor HAProxy pod scaling
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=haproxy -w
   ```

4. **Push changes to appropriate branch (GitOps workflow)**
   ```bash
   # If using GitOps (Fleet/Rancher), commit and push changes
   # Navigate to GitOps repository
   cd <gitops-repo>
   
   # Commit the cluster configuration change
   git add <path-to-cluster-config>
   git commit -m "Scale up PXC/HAProxy cluster for increased API volume"
   git push origin <appropriate-branch>
   
   # Verify GitOps sync picks up the change
   # Monitor Fleet/Rancher for deployment status
   ```

5. **Verify performance is restored**
   ```bash
   # Monitor resource usage after scaling
   kubectl top pods -n <namespace> | grep -E 'pxc|haproxy'
   
   # Check cluster status
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
   # Monitor application response times
   # Check API response time metrics
   # Verify performance degradation is resolved
   ```

## Alternate/Fallback Method

1. **If scaling reveals query or data model inefficiencies**
   ```bash
   # Identify slow queries
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT sql_text, exec_count, avg_timer_wait/1000000000000 as avg_time_sec, sum_timer_wait/1000000000000 as total_time_sec FROM performance_schema.events_statements_summary_by_digest ORDER BY sum_timer_wait DESC LIMIT 10;"
   
   # Check for missing indexes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, CARDINALITY FROM information_schema.STATISTICS WHERE TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys') ORDER BY CARDINALITY;"
   
   # Analyze query execution plans
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "EXPLAIN <problematic-query>;"
   
   # Add missing indexes
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "CREATE INDEX <index-name> ON <table-name>(<column-name>);"
   
   # Optimize data model if needed
   # Review table structures and relationships
   # Consider denormalization or partitioning for high-volume tables
   ```

2. **Implement query throttling if needed**
   ```bash
   # If query optimization is not sufficient
   # Update PerconaXtraDBCluster CR to add query throttling
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml > cluster-backup.yaml
   # Edit cluster-backup.yaml to add:
   # spec.pxc.configuration: |
   #   [mysqld]
   #   max_connections = <appropriate-limit>
   #   thread_pool_size = <appropriate-size>
   kubectl apply -f cluster-backup.yaml
   ```

## Recovery Targets

- **Restore Time Objective**: 60 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 1-3 hours

## Expected Data Loss

None

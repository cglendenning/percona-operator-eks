# Memory Exhaustion Causing OOM Kills (Out of Memory) Recovery Process

## Primary Recovery Method

1. **Identify memory issue**
   ```bash
   # Check OOM kill events
   kubectl get events -n <namespace> --field-selector reason=OOMKilling
   
   # Check CloudWatch metrics
   aws cloudwatch get-metric-statistics \
     --namespace Kubernetes \
     --metric-name pod_memory_usage_bytes \
     --dimensions Name=pod_name,Value=<pod-name> \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Average,Maximum
   
   # Check pod memory usage
   kubectl top pods -n <namespace>
   kubectl describe pod -n <namespace> <pod-name> | grep -A 5 "Limits\|Requests"
   
   # Check pod logs for OOM errors
   kubectl logs -n <namespace> <pod-name> --previous | grep -i "out of memory\|oom"
   ```

2. **Identify memory leak or memory-intensive queries**
   ```bash
   # Check running queries
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SHOW PROCESSLIST;"
   
   # Check memory usage by query
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SELECT * FROM performance_schema.memory_summary_by_thread_by_event_name ORDER BY SUM_NUMBER_OF_BYTES_ALLOC DESC LIMIT 10;"
   
   # Check buffer pool usage
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool%';"
   ```

3. **Kill memory-intensive queries/processes**
   ```bash
   # Identify problematic queries
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' ORDER BY TIME DESC;"
   
   # Kill specific query
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "KILL <query-id>;"
   
   # Kill all long-running queries
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SELECT CONCAT('KILL ', ID, ';') FROM information_schema.PROCESSLIST WHERE TIME > 300 AND COMMAND != 'Sleep';" | mysql
   ```

4. **Increase memory limits**
   ```bash
   # Update StatefulSet memory limits
   kubectl patch statefulset <pxc-sts> -n <namespace> --type=json -p='[
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/resources/limits/memory",
       "value": "<new-memory-limit>"
     }
   ]'
   
   # Wait for rolling update
   kubectl rollout status statefulset/<pxc-sts> -n <namespace>
   ```

5. **Scale up EKS node groups**
   ```bash
   # Scale up node group
   aws eks update-nodegroup-config \
     --cluster-name <cluster-name> \
     --nodegroup-name <nodegroup-name> \
     --scaling-config minSize=<new-min>,maxSize=<new-max>,desiredSize=<new-desired>
   ```

6. **Restart affected pods**
   ```bash
   # Restart pod if OOM killed
   kubectl delete pod -n <namespace> <pod-name>
   
   # Wait for pod to restart
   kubectl wait --for=condition=ready pod -n <namespace> <pod-name> --timeout=300s
   ```

7. **Verify service is restored**
   ```bash
   # Check pod memory usage
   kubectl top pods -n <namespace>
   
   # Check for OOM events
   kubectl get events -n <namespace> --field-selector reason=OOMKilling
   
   # Verify cluster health
   kubectl exec -n <namespace> <pxc-pod> -- mysql -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

## Alternate/Fallback Method

1. **Scale up EKS node groups**
   ```bash
   # Add more nodes to cluster
   aws eks update-nodegroup-config \
     --cluster-name <cluster-name> \
     --nodegroup-name <nodegroup-name> \
     --scaling-config minSize=<new-min>,maxSize=<new-max>,desiredSize=<new-desired>
   ```

2. **Enable swap temporarily (not recommended for databases)**
   ```bash
   # WARNING: Swap should be disabled for database workloads
   # Only use as last resort
   # This will significantly degrade performance
   ```

3. **Failover to secondary DC if available**
   ```bash
   # If primary DC is experiencing memory issues
   # Failover to secondary DC
   # Follow DC failover procedures
   ```

## Recovery Targets

- **Restore Time Objective**: 20 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 20-60 minutes

## Expected Data Loss

None if handled quickly; potential loss if OOM kills cause data corruption

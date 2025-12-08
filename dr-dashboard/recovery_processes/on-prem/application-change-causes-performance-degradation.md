# Application Change Causes Performance Degradation Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
```





## Primary Recovery Method

1. **Identify problematic query/change**
   ```bash
   # Check slow query log
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW VARIABLES LIKE 'slow_query_log%';"
   kubectl logs -n ${NAMESPACE} <pxc-pod> | grep -i "slow query" | tail -20
   
   # Check recent slow queries
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT * FROM mysql.slow_log ORDER BY start_time DESC LIMIT 10;"
   
   # Check running queries
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW PROCESSLIST;" | grep -v Sleep
   
   # Check EXPLAIN for problematic queries
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "EXPLAIN <problematic-query>;"
   
   # Identify full table scans
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT * FROM information_schema.PROCESSLIST WHERE INFO LIKE '%SELECT%' AND STATE LIKE '%Scan%';"
   ```

2. **Correlate with application deployment**
   ```bash
   # Check recent application deployments
   kubectl get deployments -n ${NAMESPACE} --sort-by=.metadata.creationTimestamp
   kubectl rollout history deployment/<app-deployment> -n ${NAMESPACE}
   
   # Check application logs for query patterns
   kubectl logs -n ${NAMESPACE} <app-pod> --tail=100 | grep -i "query\|select\|update\|delete"
   
   # Review git commits/deployment notes
   # Identify code changes that might have introduced inefficient queries
   ```

3. **Rollback application deployment**
   ```bash
   # Rollback to previous version
   kubectl rollout undo deployment/<app-deployment> -n ${NAMESPACE}
   
   # Monitor rollback progress
   kubectl rollout status deployment/<app-deployment> -n ${NAMESPACE}
   
   # Verify performance improves
   kubectl top pods -n ${NAMESPACE}
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW PROCESSLIST;" | grep -v Sleep
   ```

4. **Optimize query**
   ```bash
   # Analyze query execution plan
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "EXPLAIN <problematic-query>;"
   
   # Check for missing indexes
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW INDEX FROM <table-name>;"
   
   # Add missing indexes if needed
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "CREATE INDEX <index-name> ON <table-name>(<column-name>);"
   
   # Optimize query (add WHERE clauses, limit columns, add indexes)
   # Update application code with optimized query
   ```

5. **Redeploy fixed version**
   ```bash
   # Deploy optimized application version
   kubectl apply -f <fixed-app-deployment.yaml>
   
   # Monitor deployment
   kubectl rollout status deployment/<app-deployment> -n ${NAMESPACE}
   
   # Verify performance is restored
   kubectl top pods -n ${NAMESPACE}
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW PROCESSLIST;" | grep -v Sleep
   ```

6. **Verify service is restored**
   ```bash
   # Check slow query log
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SELECT COUNT(*) FROM mysql.slow_log WHERE start_time > DATE_SUB(NOW(), INTERVAL 10 MINUTE);"
   
   # Check performance metrics
   kubectl top pods -n ${NAMESPACE}
   
   # Check application response times
   kubectl logs -n ${NAMESPACE} <app-pod> --tail=50 | grep -i "response\|time"
   
   # Verify no full table scans
   kubectl exec -n ${NAMESPACE} <pxc-pod> -- mysql -e "SHOW PROCESSLIST;" | grep -i "scan"
   ```

## Alternate/Fallback Method

1. **Temporarily block problematic application endpoint**
   ```bash
   # Identify problematic endpoint
   # Update ingress/route to block endpoint
   kubectl patch ingress <app-ingress> -n ${NAMESPACE} --type=json -p='[
     {
       "op": "remove",
       "path": "/spec/rules/0/http/paths/<problematic-path>"
     }
   ]'
   ```

2. **Throttle application requests**
   ```bash
   # Update application deployment to reduce replicas
   kubectl scale deployment/<app-deployment> --replicas=1 -n ${NAMESPACE}
   
   # Or implement rate limiting in application
   # Update application configuration
   ```

3. **Scale up database resources**
   ```bash
   # Increase database resources temporarily
   kubectl patch statefulset <pxc-sts> -n ${NAMESPACE} --type=json -p='[
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/resources/limits/cpu",
       "value": "<increased-cpu>"
     },
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/resources/limits/memory",
       "value": "<increased-memory>"
     }
   ]'
   ```

## Recovery Targets

- **Restore Time Objective**: 45 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-90 minutes

## Expected Data Loss

None

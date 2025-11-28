# Single MySQL Pod Failure Recovery Process

## Primary Recovery Method
K8s restarts pod; Percona Operator re-joins PXC node automatically

### Steps

1. **Monitor pod status**
   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=pxc
   kubectl logs -n <namespace> <pod-name> --previous
   ```

2. **Wait for Kubernetes to automatically restart the failed pod**
   - Kubernetes will detect the pod failure and restart it
   - Percona Operator will detect and rejoin the node to the cluster

3. **Verify service is restored**
   ```bash
   # Verify cluster status
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
   # Confirm all nodes are synced
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Manual pod delete; ensure liveness/readiness probes healthy

### Steps

1. **Manually delete the failing pod**
   ```bash
   kubectl delete pod -n <namespace> <pod-name>
   ```

2. **Verify new pod is created**
   ```bash
   kubectl get pods -n <namespace> -w
   ```

3. **Verify service is restored**
   ```bash
   # Check liveness probe
   kubectl describe pod -n <namespace> <pod-name> | grep -A5 Liveness
   
   # Check readiness probe
   kubectl describe pod -n <namespace> <pod-name> | grep -A5 Readiness
   
   # Verify pod joins cluster and syncs data
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

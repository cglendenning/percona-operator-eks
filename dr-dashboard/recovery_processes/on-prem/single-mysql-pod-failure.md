# Single MySQL Pod Failure Recovery Process

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
```





## Primary Recovery Method
K8s restarts pod; Percona Operator re-joins PXC node automatically

### Steps

1. **Monitor pod status**
   ```bash
   kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=pxc
   kubectl logs -n ${NAMESPACE} ${POD_NAME} --previous
   ```

2. **Wait for Kubernetes to automatically restart the failed pod**
   - Kubernetes will detect the pod failure and restart it
   - Percona Operator will detect and rejoin the node to the cluster

3. **Verify service is restored**
   ```bash
   # Verify cluster status
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
   # Confirm all nodes are synced
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Manual pod delete; ensure liveness/readiness probes healthy

### Steps

1. **Manually delete the failing pod**
   ```bash
   kubectl delete pod -n ${NAMESPACE} ${POD_NAME}
   ```

2. **Verify new pod is created**
   ```bash
   kubectl get pods -n ${NAMESPACE} -w
   ```

3. **Verify service is restored**
   ```bash
   # Check liveness probe
   kubectl describe pod -n ${NAMESPACE} ${POD_NAME} | grep -A5 Liveness
   
   # Check readiness probe
   kubectl describe pod -n ${NAMESPACE} ${POD_NAME} | grep -A5 Readiness
   
   # Verify pod joins cluster and syncs data
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

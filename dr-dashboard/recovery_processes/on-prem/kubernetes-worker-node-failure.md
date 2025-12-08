# Kubernetes Worker Node Failure Recovery Process

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
Pods rescheduled by K8s; PXC node re-joins cluster

### Steps

1. **Identify failed node**
   ```bash
   kubectl get nodes
   kubectl describe node <node-name>
   ```

2. **List affected pods**
   ```bash
   kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=<node-name>
   ```

3. **Kubernetes automatically reschedules pods to healthy nodes**
   - Monitor pod rescheduling: `kubectl get pods -n ${NAMESPACE} -w`
   - Percona Operator will reconcile and rejoin rescheduled PXC pods

4. **Verify service is restored**
   ```bash
   # Check cluster health
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Verify cluster size matches expected
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
   # Test application connectivity
   ```

## Alternate/Fallback Method
Cordon/drain failing node; replace VM; verify anti-affinity rules

### Steps

1. **Cordon the node (if still accessible)**
   ```bash
   kubectl cordon <node-name>
   ```

2. **Drain the node gracefully**
   ```bash
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

3. **Replace or reboot the VM through your infrastructure provider**
   - VMware: Replace or reboot VM host

4. **Verify service is restored**
   ```bash
   # Verify anti-affinity rules are working
   kubectl get pods -n ${NAMESPACE} -o wide
   
   # Ensure pods are distributed across availability zones
   # Verify cluster health
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

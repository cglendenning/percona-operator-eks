# Kubernetes Worker Node Failure Recovery Process

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
   - Monitor pod rescheduling: `kubectl get pods -n <namespace> -w`
   - Percona Operator will reconcile and rejoin rescheduled PXC pods

4. **Verify service is restored**
   ```bash
   # Check cluster health
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Verify cluster size matches expected
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
   
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
   kubectl get pods -n <namespace> -o wide
   
   # Ensure pods are distributed across availability zones
   # Verify cluster health
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

# Kubernetes Worker Node Failure Recovery Process

## Scenario
Kubernetes worker node failure (VM host crash)

## Detection Signals
- Node NotReady status
- Pod evictions
- HAProxy backend down
- Kubelet stopped responding

## Primary Recovery Method
Pods rescheduled by K8s; PXC node re-joins cluster

### Steps
1. Identify failed node: `kubectl get nodes`
2. Check node status: `kubectl describe node <node-name>`
3. List affected pods: `kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=<node-name>`
4. Kubernetes automatically reschedules pods to healthy nodes (if PodDisruptionBudgets allow)
5. Monitor pod rescheduling: `kubectl get pods -n <namespace> -w`
6. Verify Percona Operator reconciles and rejoins rescheduled PXC pods
7. Check cluster health: `kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"`

## Alternate/Fallback Method
Cordon/drain failing node; replace VM; verify anti-affinity rules

### Steps
1. Cordon the node (if still accessible): `kubectl cordon <node-name>`
2. Drain the node gracefully: `kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data`
3. Replace or reboot the VM through your infrastructure provider (AWS, VMware, etc.)
4. Verify anti-affinity rules are working: `kubectl get pods -n <namespace> -o wide`
5. Ensure pods are distributed across availability zones
6. Uncordon node after repair: `kubectl uncordon <node-name>`

## Recovery Targets
- **RTO**: 10-20 minutes
- **RPO**: 0
- **MTTR**: 30-60 minutes

## Expected Data Loss
None

## Affected Components
- VMware host / EC2 instance
- Kubelet
- PXC pod on failed node
- Local storage (if any)

## Assumptions & Prerequisites
- PodDisruptionBudgets configured
- Topology spread constraints configured
- PVCs on shared storage (EBS, EFS) or replicated local storage
- Sufficient capacity on remaining nodes
- Anti-affinity rules prevent multiple PXC pods on same node

## Verification Steps
1. Verify all nodes Ready: `kubectl get nodes`
2. Check pod distribution: `kubectl get pods -n <namespace> -o wide`
3. Verify cluster size matches expected: `kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"`
4. Test application connectivity
5. Check for any pending PVCs: `kubectl get pvc -n <namespace>`
6. Verify ProxySQL/HAProxy backends are healthy

## Rollback Procedure
If rescheduling fails:
1. Check for resource constraints: `kubectl describe nodes`
2. Verify PVC binding
3. Check pod events: `kubectl describe pod -n <namespace> <pod-name>`
4. Consider scaling cluster or adding nodes

## Related Scenarios
- Single MySQL pod failure
- Storage PVC corruption
- Kubernetes control plane outage

# Single MySQL Pod Failure Recovery Process

## Scenario
Single MySQL pod failure (container crash / OOM)

## Detection Signals
- Pod CrashLoopBackOff
- PXC node missing
- HAProxy/ProxySQL health check fails

## Primary Recovery Method
K8s restarts pod; Percona Operator re-joins PXC node automatically

### Steps
1. Monitor pod status: `kubectl get pods -n <namespace> -l app.kubernetes.io/component=pxc`
2. Check pod logs: `kubectl logs -n <namespace> <pod-name> --previous`
3. Verify Kubernetes automatically restarts the failed pod
4. Wait for Percona Operator to detect and rejoin the node to the cluster
5. Verify cluster status: `kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"`
6. Confirm all nodes are synced: `kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"`

## Alternate/Fallback Method
Manual pod delete; ensure liveness/readiness probes healthy

### Steps
1. Manually delete the failing pod: `kubectl delete pod -n <namespace> <pod-name>`
2. Verify new pod is created: `kubectl get pods -n <namespace> -w`
3. Check liveness probe: `kubectl describe pod -n <namespace> <pod-name> | grep -A5 Liveness`
4. Check readiness probe: `kubectl describe pod -n <namespace> <pod-name> | grep -A5 Readiness`
5. Verify pod joins cluster and syncs data

## Recovery Targets
- **RTO**: 5-10 minutes
- **RPO**: 0 (no data loss)
- **MTTR**: 10-20 minutes

## Expected Data Loss
None (Galera sync)

## Affected Components
- PXC pod
- Sidecars
- Service endpoints

## Assumptions & Prerequisites
- Assumes 3+ node PXC cluster
- Quorum maintained during recovery
- No PVC corruption
- Pod anti-affinity rules in place
- Adequate resources on other nodes

## Verification Steps
1. Check cluster size: `kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep%';"`
2. Verify HAProxy/ProxySQL backend health
3. Test write operations from application
4. Monitor cluster metrics in PMM/Grafana
5. Verify no replication lag

## Rollback Procedure
N/A - If automatic recovery fails, escalate to quorum loss scenario

## Related Scenarios
- Kubernetes worker node failure
- Cluster loses quorum
- Storage PVC corruption

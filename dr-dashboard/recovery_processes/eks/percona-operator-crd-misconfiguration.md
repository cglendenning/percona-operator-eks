# Percona Operator / CRD Misconfiguration Recovery Process

## Scenario
Percona Operator / CRD misconfiguration (bad rollout)

## Detection Signals
- Pods stuck in Pending or CrashLoopBackOff status
- Operator reconciliation errors in logs
- Custom Resource validation failures
- StatefulSet not updating despite CR changes
- Operator pod crashing

## Primary Recovery Method
Rollback GitOps change in Rancher/Fleet; restore previous CR YAML

### Steps
1. Identify the bad configuration change
   ```bash
   kubectl get perconaxtradbclusters -n <namespace>
   kubectl describe perconaxtradbcluster -n <namespace> <cluster-name>
   ```

2. Check operator logs for reconciliation errors
   ```bash
   kubectl logs -n <operator-namespace> -l app.kubernetes.io/name=percona-xtradb-cluster-operator
   ```

3. Rollback via GitOps (Fleet/ArgoCD)
   - Revert the commit in Git that introduced the bad configuration
   - Push the revert
   - Wait for GitOps to sync (or force sync)

4. Alternatively, manually restore previous CR version
   ```bash
   kubectl apply -f <previous-good-cr.yaml> -n <namespace>
   ```

5. Monitor operator reconciliation
   ```bash
   kubectl logs -n <operator-namespace> -l app.kubernetes.io/name=percona-xtradb-cluster-operator -f
   ```

6. Verify StatefulSet and pods recover
   ```bash
   kubectl get statefulset -n <namespace>
   kubectl get pods -n <namespace>
   ```

## Alternate/Fallback Method
Scale down/up operator; recreate PXC from last good statefulset spec

### Steps
1. Scale down the operator temporarily
   ```bash
   kubectl scale deployment percona-xtradb-cluster-operator -n <operator-namespace> --replicas=0
   ```

2. Manually fix the Custom Resource or restore from backup
   ```bash
   kubectl edit perconaxtradbcluster -n <namespace> <cluster-name>
   # OR
   kubectl apply -f <last-known-good-cr.yaml> -n <namespace>
   ```

3. Verify CR is valid
   ```bash
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml
   ```

4. Scale operator back up
   ```bash
   kubectl scale deployment percona-xtradb-cluster-operator -n <operator-namespace> --replicas=1
   ```

5. Monitor operator reconciliation and cluster recovery

6. If StatefulSet is corrupted, manually restore it
   ```bash
   kubectl get statefulset <sts-name> -n <namespace> -o yaml > sts-backup.yaml
   # Edit and fix, then apply
   kubectl apply -f sts-backup.yaml
   ```

## Recovery Targets
- **RTO**: 15-45 minutes
- **RPO**: 0
- **MTTR**: 30-90 minutes

## Expected Data Loss
None

## Affected Components
- Percona Operator deployment
- PerconaXtraDBCluster Custom Resource
- StatefulSets (pxc, proxysql, haproxy)
- Related ConfigMaps and Secrets

## Assumptions & Prerequisites
- All changes flow via Fleet or GitOps (reviewed/approved)
- Backup of last known good manifests exists
- Git history preserved for rollback
- Operator has proper RBAC permissions
- CR validation webhooks are functioning

## Verification Steps
1. Check operator is running
   ```bash
   kubectl get pods -n <operator-namespace> -l app.kubernetes.io/name=percona-xtradb-cluster-operator
   ```

2. Verify CR status
   ```bash
   kubectl get perconaxtradbcluster -n <namespace>
   ```

3. Check StatefulSet rollout status
   ```bash
   kubectl rollout status statefulset <sts-name> -n <namespace>
   ```

4. Verify all pods are running and ready
   ```bash
   kubectl get pods -n <namespace>
   ```

5. Test database connectivity
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SELECT 1;"
   ```

6. Check cluster status
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep%';"
   ```

## Rollback Procedure
If rollback fails:
1. Retrieve previous working CR from Git history
2. Check CRD version compatibility
3. Verify operator version is compatible with CR version
4. Consider downgrading operator if CRD incompatibility exists
5. As last resort, backup data and recreate cluster from scratch

## Post-Recovery Actions
1. Document what configuration caused the issue
2. Update validation rules or admission webhooks
3. Add pre-deployment validation to CI/CD
4. Review change approval process

## Related Scenarios
- Kubernetes control plane outage
- Single MySQL pod failure
- Widespread data corruption (from bad migrations)

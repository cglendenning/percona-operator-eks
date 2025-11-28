# Percona Operator / CRD Misconfiguration Recovery Process

## Primary Recovery Method
Rollback GitOps change in Rancher/Fleet; restore previous CR YAML

### Steps

1. **Identify the bad configuration change**
   ```bash
   kubectl get perconaxtradbclusters -n <namespace>
   kubectl describe perconaxtradbcluster -n <namespace> <cluster-name>
   ```

2. **Check operator logs for reconciliation errors**
   ```bash
   kubectl logs -n <operator-namespace> -l app.kubernetes.io/name=percona-xtradb-cluster-operator
   ```

3. **Rollback via GitOps (Fleet/ArgoCD)**
   - Revert the commit in Git that introduced the bad configuration
   - Push the revert
   - Wait for GitOps to sync (or force sync)

4. **Alternatively, manually restore previous CR version**
   ```bash
   kubectl apply -f <previous-good-cr.yaml> -n <namespace>
   ```

5. **Monitor operator reconciliation**
   ```bash
   kubectl logs -n <operator-namespace> -l app.kubernetes.io/name=percona-xtradb-cluster-operator -f
   ```

6. **Verify service is restored**
   ```bash
   # Verify StatefulSet and pods recover
   kubectl get statefulset -n <namespace>
   kubectl get pods -n <namespace>
   
   # Verify cluster is healthy
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Scale down/up operator; recreate PXC from last good statefulset spec

### Steps

1. **Scale down the operator temporarily**
   ```bash
   kubectl scale deployment percona-xtradb-cluster-operator -n <operator-namespace> --replicas=0
   ```

2. **Manually fix the Custom Resource or restore from backup**
   ```bash
   kubectl edit perconaxtradbcluster -n <namespace> <cluster-name>
   # OR
   kubectl apply -f <last-known-good-cr.yaml> -n <namespace>
   ```

3. **Verify CR is valid**
   ```bash
   kubectl get perconaxtradbcluster -n <namespace> <cluster-name> -o yaml
   ```

4. **Scale operator back up**
   ```bash
   kubectl scale deployment percona-xtradb-cluster-operator -n <operator-namespace> --replicas=1
   ```

5. **If StatefulSet is corrupted, manually restore it**
   ```bash
   kubectl get statefulset <sts-name> -n <namespace> -o yaml > sts-backup.yaml
   # Edit and fix, then apply
   kubectl apply -f sts-backup.yaml
   ```

6. **Verify service is restored**
   ```bash
   # Monitor operator reconciliation and cluster recovery
   kubectl get pods -n <namespace>
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Test write operations from application
   ```

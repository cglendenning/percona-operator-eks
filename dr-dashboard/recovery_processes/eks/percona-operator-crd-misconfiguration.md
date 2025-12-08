# Percona Operator / CRD Misconfiguration Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -p "Enter PXC cluster name: " CLUSTER_NAME
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -p "Enter StatefulSet name: " STS_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
```





## Primary Recovery Method
Rollback GitOps change in Rancher/Fleet; restore previous CR YAML

### Steps

1. **Identify the bad configuration change**
   ```bash
   kubectl get perconaxtradbclusters -n ${NAMESPACE}
   kubectl describe perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME}
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
   kubectl apply -f <previous-good-cr.yaml> -n ${NAMESPACE}
   ```

5. **Monitor operator reconciliation**
   ```bash
   kubectl logs -n <operator-namespace> -l app.kubernetes.io/name=percona-xtradb-cluster-operator -f
   ```

6. **Verify service is restored**
   ```bash
   # Verify StatefulSet and pods recover
   kubectl get statefulset -n ${NAMESPACE}
   kubectl get pods -n ${NAMESPACE}
   
   # Verify cluster is healthy
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
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
   kubectl edit perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME}
   # OR
   kubectl apply -f <last-known-good-cr.yaml> -n ${NAMESPACE}
   ```

3. **Verify CR is valid**
   ```bash
   kubectl get perconaxtradbcluster -n ${NAMESPACE} ${CLUSTER_NAME} -o yaml
   ```

4. **Scale operator back up**
   ```bash
   kubectl scale deployment percona-xtradb-cluster-operator -n <operator-namespace> --replicas=1
   ```

5. **If StatefulSet is corrupted, manually restore it**
   ```bash
   kubectl get statefulset ${STS_NAME} -n ${NAMESPACE} -o yaml > sts-backup.yaml
   # Edit and fix, then apply
   kubectl apply -f sts-backup.yaml
   ```

6. **Verify service is restored**
   ```bash
   # Monitor operator reconciliation and cluster recovery
   kubectl get pods -n ${NAMESPACE}
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Test write operations from application
   ```

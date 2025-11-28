# Ingress/VIP Failure (HAProxy/ProxySQL) Recovery Process

## Primary Recovery Method
Fail traffic to alternate service/ingress; fix Service/Endpoints

### Steps

1. **Identify the problem**
   ```bash
   kubectl get svc -n <namespace>
   kubectl get endpoints -n <namespace>
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=proxysql
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=haproxy
   ```

2. **Check pod status and logs**
   ```bash
   kubectl describe pod -n <namespace> <proxysql-pod-name>
   kubectl logs -n <namespace> <proxysql-pod-name>
   ```

3. **If pods are down, let Kubernetes restart them**
   ```bash
   kubectl get pods -n <namespace> -w
   ```

4. **If pods are stuck, force restart**
   ```bash
   kubectl delete pod -n <namespace> <proxysql-pod-name>
   ```

5. **Verify Service endpoints repopulate**
   ```bash
   kubectl get endpoints -n <namespace> <service-name> -w
   ```

6. **Verify service is restored**
   ```bash
   # Test connectivity
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h <service-name>.<namespace>.svc.cluster.local -uroot -p<password> -e "SELECT 1;"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Clients connect via read/write split endpoints directly (bypass ProxySQL/HAProxy)

### Steps

1. **Identify direct PXC service endpoints**
   ```bash
   kubectl get svc -n <namespace> | grep pxc
   ```

2. **Update application configuration to use direct endpoints**
   - Primary (writes): `<cluster-name>-pxc-0.<cluster-name>-pxc.<namespace>.svc.cluster.local`
   - Read replicas: `<cluster-name>-pxc.<namespace>.svc.cluster.local` (headless service)

3. **Update DNS or ingress to point directly to PXC service**

4. **Verify service is restored**
   ```bash
   # Test direct connectivity
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h <cluster-name>-pxc.<namespace>.svc.cluster.local -uroot -p<password> -e "SELECT 1;"
   
   # Test write operations from application
   ```

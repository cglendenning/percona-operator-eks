# HAProxy Endpoints Inaccessible Recovery Process

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
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
```





## Primary Recovery Method
Fix K8s Service/Endpoints configuration; restore ingress/DNS routing; verify network connectivity

### Steps

⚠️ **NOTE**: This scenario assumes HAProxy pods are healthy and running. The issue is external (Service endpoints, ingress, DNS, or network routing) preventing application access.

1. **Verify HAProxy pods are healthy**
   ```bash
   kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=haproxy
   kubectl describe pod -n ${NAMESPACE} <haproxy-pod-name>
   kubectl logs -n ${NAMESPACE} <haproxy-pod-name>
   ```
   - Confirm pods are Running and ready
   - If pods are unhealthy, address pod issues first

2. **Check Service and Endpoints**
   ```bash
   kubectl get svc -n ${NAMESPACE} <haproxy-service-name>
   kubectl get endpoints -n ${NAMESPACE} <haproxy-service-name>
   kubectl describe endpoints -n ${NAMESPACE} <haproxy-service-name>
   ```
   - Verify Service exists and is configured correctly
   - Verify Endpoints list contains HAProxy pod IPs
   - If endpoints are empty, check pod labels match service selector

3. **Fix Service endpoints if empty**
   ```bash
   # Check service selector matches pod labels
   kubectl get svc -n ${NAMESPACE} <haproxy-service-name> -o yaml | grep selector
   kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=haproxy --show-labels
   
   # If selector mismatch, update service or pod labels
   kubectl patch svc -n ${NAMESPACE} <haproxy-service-name> -p '{"spec":{"selector":{"app.kubernetes.io/component":"haproxy"}}}'
   ```

4. **Check ingress/DNS configuration**
   ```bash
   kubectl get ingress -n ${NAMESPACE}
   kubectl describe ingress -n ${NAMESPACE} <ingress-name>
   ```
   - Verify ingress rules point to correct HAProxy service
   - Check DNS records if using external DNS
   - Verify ingress controller is running

5. **Test network connectivity**
   ```bash
   # Test from within cluster
   kubectl run -it --rm test-connectivity --image=curlimages/curl --restart=Never -- curl -v http://<haproxy-service-name>.${NAMESPACE}.svc.cluster.local:3306
   
   # Test from application namespace
   kubectl exec -n <app-namespace> <app-pod> -- nc -zv <haproxy-service-name>.${NAMESPACE}.svc.cluster.local 3306
   ```

6. **Restore ingress/DNS if needed**
   ```bash
   # Update ingress to point to HAProxy service
   kubectl patch ingress -n ${NAMESPACE} <ingress-name> -p '{"spec":{"rules":[{"host":"<hostname>","http":{"paths":[{"path":"/","backend":{"service":{"name":"<haproxy-service-name>","port":{"number":3306}}}}]}}]}}'
   
   # Or recreate ingress
   kubectl apply -f <ingress-config.yaml>
   ```

7. **Verify Service endpoints repopulate**
   ```bash
   kubectl get endpoints -n ${NAMESPACE} <haproxy-service-name> -w
   ```

8. **Verify service is restored**
   ```bash
   # Test connectivity to HAProxy service
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h <haproxy-service-name>.${NAMESPACE}.svc.cluster.local -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   
   # Test from application pod
   kubectl exec -n <app-namespace> <app-pod> -- mysql -h <haproxy-service-name>.${NAMESPACE}.svc.cluster.local -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Clients connect via read/write split endpoints directly to PXC (bypass HAProxy)

### Steps

1. **Identify direct PXC service endpoints**
   ```bash
   kubectl get svc -n ${NAMESPACE} | grep pxc
   ```

2. **Update application configuration to use direct endpoints**
   - Primary (writes): `${CLUSTER_NAME}-pxc-0.${CLUSTER_NAME}-pxc.${NAMESPACE}.svc.cluster.local`
   - Read replicas: `${CLUSTER_NAME}-pxc.${NAMESPACE}.svc.cluster.local` (headless service)

3. **Update DNS or ingress to point directly to PXC service**

4. **Verify service is restored**
   ```bash
   # Test direct connectivity
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h ${CLUSTER_NAME}-pxc.${NAMESPACE}.svc.cluster.local -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   
   # Test write operations from application
   ```

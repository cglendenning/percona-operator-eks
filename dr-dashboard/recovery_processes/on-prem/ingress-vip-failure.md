# HAProxy Endpoints Inaccessible Recovery Process

## Primary Recovery Method
Fix K8s Service/Endpoints configuration; restore ingress/DNS routing; verify network connectivity

### Steps

⚠️ **NOTE**: This scenario assumes HAProxy pods are healthy and running. The issue is external (Service endpoints, ingress, DNS, or network routing) preventing application access.

1. **Verify HAProxy pods are healthy**
   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=haproxy
   kubectl describe pod -n <namespace> <haproxy-pod-name>
   kubectl logs -n <namespace> <haproxy-pod-name>
   ```
   - Confirm pods are Running and ready
   - If pods are unhealthy, address pod issues first

2. **Check Service and Endpoints**
   ```bash
   kubectl get svc -n <namespace> <haproxy-service-name>
   kubectl get endpoints -n <namespace> <haproxy-service-name>
   kubectl describe endpoints -n <namespace> <haproxy-service-name>
   ```
   - Verify Service exists and is configured correctly
   - Verify Endpoints list contains HAProxy pod IPs
   - If endpoints are empty, check pod labels match service selector

3. **Fix Service endpoints if empty**
   ```bash
   # Check service selector matches pod labels
   kubectl get svc -n <namespace> <haproxy-service-name> -o yaml | grep selector
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=haproxy --show-labels
   
   # If selector mismatch, update service or pod labels
   kubectl patch svc -n <namespace> <haproxy-service-name> -p '{"spec":{"selector":{"app.kubernetes.io/component":"haproxy"}}}'
   ```

4. **Check ingress/DNS configuration**
   ```bash
   kubectl get ingress -n <namespace>
   kubectl describe ingress -n <namespace> <ingress-name>
   ```
   - Verify ingress rules point to correct HAProxy service
   - Check DNS records if using external DNS
   - Verify ingress controller is running

5. **Test network connectivity**
   ```bash
   # Test from within cluster
   kubectl run -it --rm test-connectivity --image=curlimages/curl --restart=Never -- curl -v http://<haproxy-service-name>.<namespace>.svc.cluster.local:3306
   
   # Test from application namespace
   kubectl exec -n <app-namespace> <app-pod> -- nc -zv <haproxy-service-name>.<namespace>.svc.cluster.local 3306
   ```

6. **Restore ingress/DNS if needed**
   ```bash
   # Update ingress to point to HAProxy service
   kubectl patch ingress -n <namespace> <ingress-name> -p '{"spec":{"rules":[{"host":"<hostname>","http":{"paths":[{"path":"/","backend":{"service":{"name":"<haproxy-service-name>","port":{"number":3306}}}}]}}]}}'
   
   # Or recreate ingress
   kubectl apply -f <ingress-config.yaml>
   ```

7. **Verify Service endpoints repopulate**
   ```bash
   kubectl get endpoints -n <namespace> <haproxy-service-name> -w
   ```

8. **Verify service is restored**
   ```bash
   # Test connectivity to HAProxy service
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h <haproxy-service-name>.<namespace>.svc.cluster.local -uroot -p<password> -e "SELECT 1;"
   
   # Test from application pod
   kubectl exec -n <app-namespace> <app-pod> -- mysql -h <haproxy-service-name>.<namespace>.svc.cluster.local -uroot -p<password> -e "SELECT 1;"
   
   # Test write operations from application
   ```

## Alternate/Fallback Method
Clients connect via read/write split endpoints directly to PXC (bypass HAProxy)

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

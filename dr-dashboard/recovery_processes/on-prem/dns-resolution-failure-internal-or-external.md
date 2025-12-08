# DNS Resolution Failure (Internal or External) Recovery Process

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
```





## Primary Recovery Method

1. **Identify DNS failure**
   ```bash
   # Test DNS resolution
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- nslookup <database-hostname>
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- dig <database-hostname>
   
   # Check DNS server status
   kubectl get pods -n kube-system | grep dns
   kubectl logs -n kube-system <dns-pod-name>
   
   # Check DNS configuration
   kubectl get configmap -n kube-system coredns -o yaml
   ```

2. **Fix DNS server/configuration**
   ```bash
   # Restart CoreDNS if needed
   kubectl rollout restart deployment coredns -n kube-system
   
   # Check DNS service
   kubectl get svc -n kube-system kube-dns
   
   # Verify DNS resolution after restart
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- nslookup <database-hostname>
   ```

3. **Update /etc/hosts as temporary workaround**
   ```bash
   # Get database service IP
   kubectl get svc -n ${NAMESPACE} <database-service-name>
   
   # Add to /etc/hosts in pods (temporary)
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- sh -c 'echo "<ip-address> <hostname>" >> /etc/hosts'
   
   # Or update application connection strings to use IP directly
   ```

4. **Restore DNS service**
   ```bash
   # Check DNS pod status
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   
   # If DNS pods are failing, check events
   kubectl describe pod -n kube-system <dns-pod-name>
   
   # Restore DNS configuration from backup if needed
   kubectl apply -f <dns-config-backup.yaml>
   ```

5. **Verify service is restored**
   ```bash
   # Test DNS resolution
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- nslookup <database-hostname>
   
   # Test application connectivity
   kubectl exec -n ${NAMESPACE} <app-pod> -- curl -v <database-hostname>:3306
   
   # Monitor DNS resolution
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- dig <database-hostname> +short
   ```

## Alternate/Fallback Method

1. **Use IP addresses directly**
   ```bash
   # Get database service IP
   kubectl get svc -n ${NAMESPACE} <database-service-name> -o jsonpath='{.spec.clusterIP}'
   
   # Update application connection strings to use IP
   # Update environment variables or configuration files
   kubectl set env deployment/<app-deployment> DB_HOST=<ip-address> -n ${NAMESPACE}
   
   # Restart application pods
   kubectl rollout restart deployment/<app-deployment> -n ${NAMESPACE}
   ```

2. **Restore DNS when available**
   ```bash
   # Once DNS is restored, revert to hostname-based connections
   kubectl set env deployment/<app-deployment> DB_HOST=<hostname> -n ${NAMESPACE}
   kubectl rollout restart deployment/<app-deployment> -n ${NAMESPACE}
   ```

## Recovery Targets

- **Restore Time Objective**: 30 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-60 minutes

## Expected Data Loss

None

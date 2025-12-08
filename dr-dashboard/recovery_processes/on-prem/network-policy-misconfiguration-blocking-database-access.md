# Network Policy Misconfiguration Blocking Database Access Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
```





## Primary Recovery Method

1. **Identify network policy issue**
   ```bash
   # Check network policies
   kubectl get networkpolicies -n ${NAMESPACE}
   kubectl describe networkpolicy -n ${NAMESPACE} <policy-name>
   
   # Check pod connectivity
   kubectl exec -n ${NAMESPACE} <app-pod> -- ping <database-pod-ip>
   kubectl exec -n ${NAMESPACE} <app-pod> -- telnet <database-pod-ip> 3306
   
   # Check network policy logs
   kubectl logs -n kube-system -l k8s-app=calico | grep -i "deny\|block"
   ```

2. **Identify and fix network policy rules**
   ```bash
   # Review network policy rules
   kubectl get networkpolicy -n ${NAMESPACE} <policy-name> -o yaml
   
   # Update network policy to allow database access
   kubectl patch networkpolicy -n ${NAMESPACE} <policy-name> --type=json -p='[
     {
       "op": "add",
       "path": "/spec/ingress/-",
       "value": {
         "from": [
           {
             "podSelector": {
               "matchLabels": {
                 "app": "<app-label>"
               }
             }
           }
         ],
         "ports": [
           {
             "protocol": "TCP",
             "port": 3306
           }
         ]
       }
     }
   ]'
   ```

3. **Update NetworkPolicy resources**
   ```bash
   # Edit network policy
   kubectl edit networkpolicy -n ${NAMESPACE} <policy-name>
   
   # Or apply corrected network policy
   kubectl apply -f <corrected-network-policy.yaml>
   ```

4. **Verify pod-to-pod connectivity**
   ```bash
   # Test connectivity from app pod to database
   kubectl exec -n ${NAMESPACE} <app-pod> -- telnet <database-service> 3306
   
   # Test database connection
   kubectl exec -n ${NAMESPACE} <app-pod> -- mysql -h <database-service> -u <user> -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;"
   
   # Check network policy allow logs
   kubectl logs -n kube-system -l k8s-app=calico | grep -i "allow"
   ```

5. **Verify service is restored**
   ```bash
   # Test application connectivity
   kubectl exec -n ${NAMESPACE} <app-pod> -- curl -v <database-endpoint>
   
   # Check application logs
   kubectl logs -n ${NAMESPACE} <app-pod> | grep -i "database\|connection"
   
   # Monitor network policy metrics
   kubectl top pods -n ${NAMESPACE}
   ```

## Alternate/Fallback Method

1. **Temporarily remove restrictive network policies**
   ```bash
   # WARNING: This reduces security, use only as last resort
   # Delete network policy
   kubectl delete networkpolicy -n ${NAMESPACE} <policy-name>
   
   # Verify connectivity restored
   kubectl exec -n ${NAMESPACE} <app-pod> -- telnet <database-service> 3306
   ```

2. **Use service mesh bypass if available**
   ```bash
   # If using service mesh, bypass network policies
   # Update service mesh configuration
   # Allow direct pod-to-pod communication
   ```

3. **Restore from network policy backup**
   ```bash
   # Restore network policy from backup
   kubectl apply -f <network-policy-backup.yaml>
   
   # Verify network policy restored
   kubectl get networkpolicy -n ${NAMESPACE}
   ```

## Recovery Targets

- **Restore Time Objective**: 30 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 20-60 minutes

## Expected Data Loss

None

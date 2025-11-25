# Ingress/VIP Failure (HAProxy/ProxySQL) Recovery Process

## Scenario
Ingress/VIP failure - HAProxy or ProxySQL service unreachable

## Detection Signals
- Health checks failing
- HTTP 502/503 errors from application
- Service endpoints empty or unhealthy
- ProxySQL or HAProxy pods not running
- Connection timeouts from application layer
- Kubernetes Service has no ready endpoints

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

3. **Verify Service selector and port configuration**
   ```bash
   kubectl get svc <service-name> -n <namespace> -o yaml
   kubectl describe svc <service-name> -n <namespace>
   ```

4. **If pods are down, let Kubernetes restart them**
   ```bash
   kubectl get pods -n <namespace> -w
   ```

5. **If pods are stuck, force restart**
   ```bash
   kubectl delete pod -n <namespace> <proxysql-pod-name>
   ```

6. **Verify Service endpoints repopulate**
   ```bash
   kubectl get endpoints -n <namespace> <service-name> -w
   ```

7. **Test connectivity**
   ```bash
   # From a test pod or using port-forward
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h <service-name>.<namespace>.svc.cluster.local -uroot -p<password> -e "SELECT 1;"
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

4. **Implement application-level connection pooling and failover logic**

5. **Fix ProxySQL/HAProxy in parallel while app uses direct connections**

6. **Once fixed, revert application back to ProxySQL/HAProxy**

## Recovery Targets
- **RTO**: 10-30 minutes
- **RPO**: 0
- **MTTR**: 30-60 minutes

## Expected Data Loss
None

## Affected Components
- Kubernetes Service object
- HAProxy/ProxySQL pods
- Service endpoints
- DNS/Ingress
- Application connection pools

## Assumptions & Prerequisites
- Dual ingress paths available (ProxySQL and direct)
- Service monitors configured
- Out-of-band jump path exists for emergency access
- Application can handle connection retries
- Load balancer health checks configured correctly

## Verification Steps
1. **Verify pods are running**
   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=proxysql
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=haproxy
   ```

2. **Check pod readiness**
   ```bash
   kubectl get pods -n <namespace> -o wide
   ```

3. **Verify Service endpoints**
   ```bash
   kubectl get endpoints -n <namespace>
   ```

4. **Test Service DNS resolution**
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup <service-name>.<namespace>.svc.cluster.local
   ```

5. **Test database connectivity through Service**
   ```bash
   kubectl run -it --rm debug --image=mysql:8.0 --restart=Never -- mysql -h <service-name>.<namespace>.svc.cluster.local -uroot -p<password> -e "SELECT 1;"
   ```

6. **Verify ProxySQL backend health**
   ```bash
   kubectl exec -n <namespace> <proxysql-pod-name> -- mysql -h127.0.0.1 -P6032 -uadmin -padmin -e "SELECT * FROM mysql_servers;"
   kubectl exec -n <namespace> <proxysql-pod-name> -- mysql -h127.0.0.1 -P6032 -uadmin -padmin -e "SELECT * FROM stats_mysql_connection_pool;"
   ```

7. **Check application connection metrics**
   - Monitor connection pool status
   - Check application error rates
   - Verify request latency has returned to normal

## Troubleshooting Common Issues

### Service has no endpoints
- Check pod labels match Service selector
- Verify pods are in Ready state
- Check readiness probes are passing

### Pods crashing
- Check resource limits (CPU/memory)
- Verify configuration (ConfigMaps)
- Check for PVC issues
- Review pod logs for errors

### DNS not resolving
- Verify CoreDNS is running
- Check Service exists in correct namespace
- Test DNS from within cluster

### Network policies blocking traffic
- Review NetworkPolicy objects
- Verify ingress/egress rules allow traffic
- Check for any admission webhooks blocking requests

## Rollback Procedure
If Service changes made things worse:
```bash
# Restore previous Service configuration
kubectl apply -f <previous-service-config.yaml>

# Or edit Service to fix
kubectl edit svc <service-name> -n <namespace>
```

## Post-Recovery Actions
1. Review Service and pod configurations for mismatches
2. Implement better health checks on ProxySQL/HAProxy
3. Set up alerts for endpoint count dropping to zero
4. Consider implementing redundant ingress paths
5. Document the incident and update runbooks
6. Review PodDisruptionBudget for proxy tier

## Related Scenarios
- Single MySQL pod failure
- Kubernetes worker node failure
- Percona Operator / CRD misconfiguration
- Primary DC network partition

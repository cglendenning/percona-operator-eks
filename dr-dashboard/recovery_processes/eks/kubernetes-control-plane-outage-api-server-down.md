# Kubernetes Control Plane Outage (API Server Down) Recovery Process

## Scenario
Kubernetes control plane outage (API server down)

## Detection Signals
- kubectl commands timeout
- Rancher dashboard unhealthy/unreachable
- etcd alarms
- API server pods not responding
- Control plane nodes NotReady
- Unable to create/modify Kubernetes resources

## Primary Recovery Method
Restore control plane VMs; failover etcd; use Rancher to re-provision

### Steps

⚠️ **CRITICAL**: Database pods keep running, but cannot be managed!

1. **Verify control plane outage**
   ```bash
   # Test API server
   kubectl cluster-info
   # Should timeout or show error
   
   # Test from different location/machine
   curl -k https://<api-server>:6443/healthz
   ```

2. **Check application status (database likely still running)**
   ```bash
   # Try to access database directly (bypassing k8s)
   # If you have direct access to nodes:
   ssh <node-ip>
   docker ps | grep mysql
   # Containers should still be running
   ```

3. **Assess control plane component status**
   
   If you have access to control plane nodes:
   ```bash
   # SSH to control plane node
   ssh <control-plane-node>
   
   # Check control plane pods
   docker ps | grep kube-apiserver
   docker ps | grep etcd
   docker ps | grep kube-controller
   docker ps | grep kube-scheduler
   
   # Check logs
   journalctl -u kubelet -n 100
   ```

4. **For managed Kubernetes (EKS):**
   ```bash
   # Check AWS service health
   aws eks describe-cluster --name <cluster-name>
   
   # Check CloudWatch logs
   aws logs tail /aws/eks/<cluster-name>/cluster --follow
   
   # Open AWS support ticket if needed
   ```

5. **For self-managed Kubernetes:**
   
   **Option A: Restart control plane components**
   ```bash
   # On control plane node
   sudo systemctl restart kubelet
   sudo systemctl restart docker  # or containerd
   
   # Wait for pods to restart
   watch docker ps
   ```
   
   **Option B: Restore etcd from backup**
   ```bash
   # Stop API server
   sudo systemctl stop kube-apiserver
   
   # Restore etcd snapshot
   sudo etcdctl snapshot restore /backup/etcd-snapshot.db \
     --data-dir=/var/lib/etcd-restored
   
   # Update etcd to use restored data
   sudo systemctl stop etcd
   sudo mv /var/lib/etcd /var/lib/etcd-old
   sudo mv /var/lib/etcd-restored /var/lib/etcd
   sudo systemctl start etcd
   
   # Restart API server
   sudo systemctl start kube-apiserver
   ```
   
   **Option C: Provision new control plane**
   - Use Rancher or cluster provisioning tool
   - Join to existing etcd cluster
   - Restore etcd data if needed

6. **Verify control plane recovery**
   ```bash
   # Test kubectl access
   kubectl cluster-info
   kubectl get nodes
   kubectl get pods --all-namespaces
   
   # Check component health
   kubectl get componentstatuses
   ```

7. **Verify database pods still healthy**
   ```bash
   # Check PXC pods
   kubectl get pods -n percona
   
   # Verify cluster status
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

8. **Check for any pod disruptions during outage**
   ```bash
   # Check events
   kubectl get events -n percona --sort-by='.lastTimestamp'
   
   # Check for restarts
   kubectl get pods -n percona -o json | jq '.items[] | {name: .metadata.name, restarts: .status.containerStatuses[].restartCount}'
   ```

## Alternate/Fallback Method
Operate cluster as-is (pods keep running); avoid changes until API is back

### Steps

1. **Access pods directly on nodes**
   ```bash
   # SSH to worker nodes
   ssh <worker-node>
   
   # List running containers
   docker ps | grep mysql
   
   # Access database directly
   docker exec -it <container-id> mysql -uroot -p<pass>
   ```

2. **Monitor database health without Kubernetes**
   ```bash
   # Check database is accepting connections
   docker exec <container-id> mysql -uroot -p<pass> -e "SELECT 1;"
   
   # Monitor logs
   docker logs -f <container-id>
   ```

3. **DO NOT restart pods or change configurations**
   - Pods continue running without API server
   - Changes cannot be applied
   - Wait for control plane recovery

4. **Set up temporary monitoring**
   - Direct node access for monitoring
   - Application-level health checks
   - Database connection tests

## Recovery Targets
- **RTO**: 30-90 minutes
- **RPO**: 0
- **MTTR**: 1-3 hours

## Expected Data Loss
None (database continues running)

## Affected Components
- etcd
- API server
- kube-controller-manager
- kube-scheduler
- Kubernetes control plane nodes

## Assumptions & Prerequisites
- Application continues if no scaling needed
- Pods don't restart during outage (liveness probes may fail)
- etcd backups exist and are tested
- Control plane is HA (3+ nodes)
- Direct node access available for emergencies

## Verification Steps

1. **Control plane fully functional**
   ```bash
   kubectl cluster-info
   kubectl get componentstatuses
   kubectl get nodes
   ```

2. **API server responsive**
   ```bash
   kubectl get --raw /healthz
   kubectl get --raw /readyz
   ```

3. **etcd healthy**
   ```bash
   kubectl exec -n kube-system <etcd-pod> -- etcdctl endpoint health
   kubectl exec -n kube-system <etcd-pod> -- etcdctl endpoint status
   ```

4. **Database pods healthy**
   ```bash
   kubectl get pods -n percona
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'wsrep%';"
   ```

5. **Test pod operations**
   ```bash
   # Test creating a test pod
   kubectl run test --image=busybox --restart=Never -- sleep 10
   kubectl delete pod test
   ```

## Rollback Procedure
If control plane recovery fails:
1. Keep database running on nodes
2. Access directly via node IPs
3. Plan migration to new cluster
4. Consider promoting replica cluster to primary

## Post-Recovery Actions

1. **Root cause analysis**
   - What caused control plane failure?
   - etcd corruption? Node failure? Resource exhaustion?

2. **Review HA configuration**
   - Ensure 3+ control plane nodes
   - Verify control plane is spread across availability zones
   - Check resource limits on control plane

3. **Enhance etcd backup**
   - Automate hourly etcd snapshots
   - Store snapshots in S3
   - Test etcd restore regularly
   - Monitor etcd disk I/O and latency

4. **Implement better monitoring**
   - Alert on API server health
   - Monitor etcd cluster health
   - Track control plane resource usage
   - Set up out-of-band monitoring

5. **Update procedures**
   - Document direct node access procedures
   - Create emergency runbook for controlplane failure
   - Test failure scenarios in staging
   - Train team on control plane recovery

6. **Consider managed control plane**
   - EKS, GKE, or AKS for managed control plane
   - Reduces operational burden
   - Built-in HA and backups

## Related Scenarios
- Kubernetes worker node failure
- etcd data corruption
- Primary DC power/cooling outage
- Ransomware attack (if control plane compromised)

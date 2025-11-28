# Kubernetes Control Plane Outage (API Server Down) Recovery Process

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

2. **For on-prem Kubernetes:**
   
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

3. **Verify service is restored**
   ```bash
   # Test kubectl access
   kubectl cluster-info
   kubectl get nodes
   kubectl get pods --all-namespaces
   
   # Verify database pods still healthy
   kubectl get pods -n percona
   kubectl exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Test write operations from application
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

3. **Verify service is restored**
   ```bash
   # Verify database is operational
   docker exec <container-id> mysql -uroot -p<pass> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   
   # Test write operations from application (if application can connect directly)
   ```

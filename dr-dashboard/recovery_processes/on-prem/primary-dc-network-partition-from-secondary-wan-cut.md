# Primary DC Network Partition from Secondary (WAN Cut) Recovery Process

## Scenario
Primary DC network partition from Secondary (WAN cut)

## Detection Signals
- Replication IO thread error
- Ping loss between datacenters
- WAN monitoring alerts
- Replication lag increasing rapidly
- Network connectivity tests failing

## Primary Recovery Method
Stay primary in current DC; queue async replication; monitor lag

### Steps
1. **Verify the partition**
   ```bash
   # Check replication status
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G"
   
   # Test network connectivity to secondary DC
   ping <secondary-dc-endpoint>
   traceroute <secondary-dc-endpoint>
   ```

2. **Confirm primary DC is healthy**
   ```bash
   kubectl get nodes
   kubectl get pods -n <namespace>
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
   ```

3. **Monitor replication lag**
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

4. **Continue accepting writes in primary DC**
   - Application continues normal operation
   - Transactions are queued for replication
   - Monitor binlog accumulation

5. **Alert operations team**
   - Notify that secondary DC is out of sync
   - Coordinate with network/infrastructure teams
   - Monitor WAN circuit status

6. **When WAN connectivity is restored**
   ```bash
   # Verify replication resumes
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G"
   
   # Monitor catch-up progress
   watch -n 5 "kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind_Master"
   ```

## Alternate/Fallback Method
If app tier in secondary is hot-standby, execute app failover if primary DC instability persists

## Recovery Targets
- **RTO**: 0 (no failover by default)
- **RPO**: N/A (stays primary)
- **MTTR**: 30-120 minutes (provider repair)

## Expected Data Loss
None (no role change)

## Related Scenarios
- Primary DC power/cooling outage
- Both DCs up but replication stops
- Credential compromise

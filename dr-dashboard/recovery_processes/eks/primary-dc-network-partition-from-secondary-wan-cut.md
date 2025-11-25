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

### Steps
1. **Assess primary DC stability**
   - If primary DC is experiencing cascading failures
   - If partition is due to primary DC network issues
   - If prolonged outage is expected

2. **Prepare secondary DC for promotion**
   ```bash
   # Verify secondary DC health
   # Check last applied transaction
   # Ensure secondary has all data needed for operations
   ```

3. **Stop writes to primary**
   - Put application in read-only mode
   - Drain in-flight transactions
   - Wait for replication to catch up (if possible)

4. **Promote secondary to primary**
   - Update DNS/ingress to point to secondary DC
   - Reconfigure application to use secondary
   - Enable writes on secondary

5. **Communicate status**
   - Notify stakeholders of DC failover
   - Update status page
   - Document the change

## Recovery Targets
- **RTO**: 0 (no failover by default)
- **RPO**: N/A (stays primary)
- **MTTR**: 30-120 minutes (provider repair)

## Expected Data Loss
None (no role change)

## Affected Components
- WAN connection
- Routers and firewalls
- Replication channel
- Network monitoring systems

## Assumptions & Prerequisites
- Percona Replication is asynchronous (async lag expected)
- Avoid split-brain by NOT auto-failing over
- WAN connectivity will be restored by infrastructure team
- Primary DC remains stable and operational
- Sufficient binlog retention to replay transactions
- Secondary DC can catch up once connectivity restored

## Verification Steps
1. **Check primary cluster health**
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW STATUS LIKE 'wsrep%';"
   ```

2. **Monitor application health**
   - Check error rates
   - Verify write operations succeed
   - Monitor connection pools

3. **Track replication lag**
   ```bash
   # If replication is working
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

4. **Verify binlog accumulation**
   ```bash
   kubectl exec -n <namespace> <pod-name> -- mysql -uroot -p<password> -e "SHOW BINARY LOGS;"
   ```

5. **Test WAN connectivity periodically**
   ```bash
   ping -c 5 <secondary-dc-endpoint>
   ```

## Rollback Procedure
N/A - This is a network issue requiring infrastructure repair, not a configuration change to rollback.

## Post-Recovery Actions
1. **Verify replication caught up**
   - Monitor Seconds_Behind_Master until 0
   - Verify data consistency between DCs
   - Check for errant transactions

2. **Review incident**
   - Root cause analysis of WAN failure
   - Review circuit redundancy
   - Consider additional WAN providers

3. **Update monitoring**
   - Ensure WAN monitoring alerts are working
   - Add replication lag dashboards
   - Set up automated health checks

4. **Test DR failover**
   - Schedule controlled failover test
   - Verify secondary DC can be promoted
   - Document and improve runbooks

## Related Scenarios
- Primary DC power/cooling outage
- Both DCs up but replication stops
- Credential compromise
- Kubernetes control plane outage

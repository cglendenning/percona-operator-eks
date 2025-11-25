# Primary DC Power/Cooling Outage (Site Down) Recovery Process

## Scenario
Primary DC power/cooling outage (site down)

## Detection Signals
- Site monitoring shows red status
- All nodes unreachable from outside DC
- Out-of-band alerts from facility management
- Complete loss of connectivity to primary DC
- Secondary DC still operational

## Primary Recovery Method
Promote Secondary DC replica to primary (planned role swap)

### Steps

⚠️ **CRITICAL**: This is a major failover event requiring coordination

1. **Confirm primary DC is completely down**
   ```bash
   # From secondary DC or external location
   ping <primary-dc-nodes>
   kubectl --context=primary-dc cluster-info  # Should timeout
   ```

2. **Verify secondary DC is healthy**
   ```bash
   kubectl --context=secondary-dc get nodes
   kubectl --context=secondary-dc get pods -n percona
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SELECT 1;"
   ```

3. **Check replication lag on secondary**
   ```bash
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

4. **Stop writes to primary (if any route still exists)**
   - Update DNS to point to secondary DC
   - Update load balancers
   - Notify application teams to pause deployments

5. **Promote secondary to primary**
   ```bash
   # Stop replication on secondary
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "STOP SLAVE;"
   
   # Reset slave status (make it standalone)
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "RESET SLAVE ALL;"
   
   # Verify it's writable
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'read_only';"
   ```

6. **Update DNS and ingress**
   - Update external DNS A records to point to secondary DC
   - Update ingress/load balancer configurations
   - Verify DNS propagation: `dig <your-db-endpoint>`

7. **Update application configuration**
   - Point applications to new primary endpoint
   - Restart application pods if needed
   - Verify write operations succeed

8. **Communicate status**
   - Update status page
   - Notify stakeholders of DC failover
   - Document failover time and actions taken

## Alternate/Fallback Method
Restore latest backup to Secondary if replica is stale/unhealthy

### Steps
1. If secondary replica is too far behind or corrupted
2. Restore latest backup to secondary DC
3. Apply point-in-time recovery from binlogs
4. Verify data integrity
5. Promote to primary

## Recovery Targets
- **RTO**: 30-120 minutes
- **RPO**: 30-120 seconds (typical async lag)
- **MTTR**: 2-6 hours (site), but service restored on secondary in ≤2 hours

## Expected Data Loss
Up to replication lag at failover (seconds → minutes)

## Affected Components
- Entire primary Kubernetes cluster
- Storage systems
- Network infrastructure
- Power/cooling systems

## Assumptions & Prerequisites
- Secondary DC replica configured and replicating
- DNS/ingress switch prepared and tested
- Application can tolerate brief downtime during cutover
- Runbooks documented and rehearsed
- Writes can be paused during role change

## Verification Steps
1. **Verify secondary is now primary**
   ```bash
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "SHOW VARIABLES LIKE 'read_only';"  # Should be OFF
   ```

2. **Test write operations**
   ```bash
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   ```

3. **Verify application connectivity**
   - Check application logs for successful DB connections
   - Test key workflows end-to-end

4. **Monitor cluster health**
   - Check Galera cluster status
   - Verify all nodes in sync
   - Monitor metrics in PMM/Grafana

## Rollback Procedure
Once primary DC is restored:
1. **Do NOT immediately fail back** - assess situation first
2. Verify primary DC is fully operational
3. Configure primary as replica of secondary
4. Let it catch up completely
5. Plan maintenance window for role swap back
6. Coordinate with teams for planned failback

## Post-Recovery Actions
1. **Root cause analysis** with facilities team
2. **Review power/cooling redundancy**
3. **Test failback procedures** when primary restored
4. **Update RTO/RPO** based on actual performance
5. **Schedule failover drills** more frequently
6. **Document lessons learned**
7. **Review insurance and contracts** for site outages

## Related Scenarios
- Primary DC network partition
- Both DCs up but replication stops
- Kubernetes control plane outage
- Ransomware attack

# Ransomware on VMware Hosts (Storage Encrypted) Recovery Process

## Primary Recovery Method
Isolate; rebuild hosts; restore K8s and PXC from clean backups in secondary DC

### Steps

⚠️ **CRITICAL**: Do NOT pay ransom! Follow incident response procedures!

1. **ISOLATE IMMEDIATELY**
   ```bash
   # Disconnect affected systems from network
   # On vCenter:
   - Shut down affected VMs (do NOT delete)
   - Disconnect network adapters
   - Take snapshots (may help forensics)
   
   # Block affected IP ranges at firewall
   # Isolate management network
   # Disable VPN access
   ```

2. **Failover to secondary DC immediately**
   ```bash
   # If secondary DC is clean and replicating
   # Promote secondary to primary (see Primary DC outage runbook)
   
   # Update DNS to point to secondary DC
   # Notify applications of new database endpoint
   # Verify secondary DC has no signs of infection
   ```

3. **Verify service is restored**
   ```bash
   # Test write operations on secondary DC
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
   # Verify application connectivity
   # Check application logs for successful DB connections
   ```

## Alternate/Fallback Method
Failover to Secondary DC replica; rebuild primary later

### Steps

1. **Immediately fail to secondary DC**
   - See "Primary DC power/cooling outage" runbook
   - Promote secondary to primary
   - Verify secondary is clean

2. **Verify service is restored**
   ```bash
   # Test write operations on secondary DC
   kubectl --context=secondary-dc exec -n percona <pod> -- mysql -uroot -p<pass> -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
   # Verify application connectivity
   ```

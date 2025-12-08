# Ransomware on VMware Hosts (Storage Encrypted) Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
read -sp "Enter MySQL root password: " MYSQL_ROOT_PASSWORD; echo
read -p "Enter secondary DC kubectl context: " SECONDARY_CONTEXT
```





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
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
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
   kubectl --context=${SECONDARY_CONTEXT} exec -n percona ${POD_NAME} -- mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test; CREATE TABLE IF NOT EXISTS test (id INT); INSERT INTO test VALUES (1);"
   
   # Verify application connectivity
   ```

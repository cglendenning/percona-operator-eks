# PXC Load Testing Monitoring

This directory contains tools to monitor your Percona XtraDB Cluster (PXC) during load testing.

## Files

- `pxc-load-test-queries.sql` - Comprehensive SQL queries for manual monitoring
- `monitor-pxc-load-test.sh` - Automated monitoring script with real-time dashboard
- `README.md` - This documentation

## Quick Start

### Option 1: Automated Monitoring Script (Recommended)

```bash
# Dashboard mode (default) - single screen that refreshes values only, no files created
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p

# Dashboard mode with report saving
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p --save-reports

# Scrolling mode - traditional output that scrolls
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p --scroll

# Provide password directly - with space
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p mypassword

# Provide password directly - MySQL style (no space)
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -pmypassword

# Custom refresh interval (10 seconds instead of 5)
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p -i 10

# Save reports to custom directory
./monitoring/monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p -o /tmp/mysql-reports

# Custom connection settings
./monitoring/monitor-pxc-load-test.sh -h mysql-cluster.example.com -P 3307 -u admin -p
```

### Option 2: Manual SQL Queries

Connect to your PXC cluster and run queries from `pxc-load-test-queries.sql`:

```bash
mysql -h 127.0.0.1 -P 3306 -u root -p < pxc-load-test-queries.sql
```

## Features

- **Dashboard Mode**: Single-screen refreshing display (like `top` or `htop`) - default behavior
  - Only values update, not the entire screen
  - Static labels drawn once for clean display
  - No files created unless explicitly requested
- **Scrolling Mode**: Traditional scrolling output available with `--scroll` flag
- **Real-time Monitoring**: Continuous monitoring with configurable refresh intervals (default: 5 seconds)
- **Daemon Mode**: Runs as a continuous process until interrupted (Ctrl+C)
- **Cluster Health**: Monitor Galera cluster status, node synchronization, and flow control
- **Performance Metrics**: Track connections, queries, InnoDB performance, and buffer pool efficiency
- **Resource Monitoring**: Memory usage, I/O statistics, and system resources
- **Storage Monitoring**: PVC usage and capacity (Kubernetes environments)
- **Optional Reports**: Reports only saved when `--save-reports` or `-o` is specified
- **Responsive Layout**: Optimized for wide terminals (170 columns), adapts to smaller sizes

## What to Monitor During Load Testing

### 🔴 Critical Alerts (Stop Testing)

1. **Cluster Status ≠ Primary** - Cluster has split-brain or lost quorum
2. **wsrep_ready = OFF** - Node not ready to process writes
3. **wsrep_flow_control_paused > 0** - Cluster is bottlenecked
4. **High Queue Sizes** - Replication falling behind
5. **PVC Usage > 90%** - Storage near capacity (K8s environments)

### 🟡 Performance Warnings

1. **Buffer Pool Hit Rate < 95%** - Memory pressure
2. **Lock Waits > 0** - Concurrency issues
3. **High Connection Count** - Connection pool exhaustion
4. **Slow Queries** - Performance degradation
5. **PVC Usage 75-90%** - Storage filling up (K8s environments)

### 🟢 Normal Operation

1. **Cluster Size = 3** - All nodes online
2. **Flow Control = 0** - No bottlenecks
3. **Queue Sizes = 0** - Replication in sync
4. **Buffer Pool Hit Rate > 99%** - Good cache efficiency
5. **PVC Usage < 75%** - Adequate storage available (K8s environments)

## Key Metrics Explained

### Cluster Health
- **wsrep_cluster_size**: Number of nodes (should be 3)
- **wsrep_cluster_status**: Should be "Primary"
- **wsrep_ready**: Should be "ON"
- **wsrep_connected**: Should be "ON"

### Performance Bottlenecks
- **wsrep_flow_control_paused**: Time cluster spent paused (should be 0)
- **wsrep_local_recv_queue**: Messages waiting to apply
- **wsrep_local_send_queue**: Messages waiting to send

### Node Performance
- **Innodb_buffer_pool_hit_rate**: Cache efficiency (>95% good)
- **Active connections**: Current client connections
- **Lock waits**: Concurrency conflicts

### Storage Metrics (Kubernetes only)
- **PVC Capacity**: Total storage allocated to each PVC
- **PVC Used**: Actual disk space consumed
- **PVC Available %**: Percentage of storage used (color-coded)
  - 🟢 Green: < 75% used
  - 🟡 Yellow: 75-90% used
  - 🔴 Red: > 90% used
- **Storage Class**: Type of storage provisioner used

## Sample Output

### Basic Output (All Environments)

```
=================================================================
[2025-11-12 10:30:15] Monitoring Cluster Status...
=== CLUSTER HEALTH OVERVIEW ===
+-------------+------------------+----------------+
| Metric      | Value            | Status         |
+-------------+------------------+----------------+
| Cluster Size| 3                | ✅ GOOD        |
| Cluster Status| Primary        | ✅ GOOD        |
| Node Ready  | ON               | ✅ GOOD        |
| Flow Control| 0.000000         | ✅ GOOD        |
+-------------+------------------+----------------+

=== REPLICATION QUEUES ===
+-------------+------+----------------+
| Queue       | Size | Status         |
+-------------+------+----------------+
| Local Recv  | 0    | ✅ GOOD        |
| Local Send  | 0    | ✅ GOOD        |
+-------------+------+----------------+
```

### Storage Output (Kubernetes Environments)

```
[2025-11-25 10:30:20] Monitoring Storage (PVCs in namespace: default)...
=== PERSISTENT VOLUME CLAIMS (PVCs) ===
NAME                                     STATUS     CAPACITY     USED         AVAIL%  
------------------------------------------------------------------------------------
datadir-cluster1-pxc-0                   Bound      10Gi         2.1G         21%   
datadir-cluster1-pxc-1                   Bound      10Gi         2.2G         22%   
datadir-cluster1-pxc-2                   Bound      10Gi         2.0G         20%   

=== STORAGE CLASS USAGE ===
gp3-encrypted                            3 PVCs
```

## Prerequisites

### Required
- `mysql` client (MySQL command-line client)
- `bash` 4.0 or higher

### Optional (for Kubernetes storage monitoring)
- `kubectl` (Kubernetes CLI)
- `jq` (JSON processor)

### Installation on WSL/Ubuntu/Debian
```bash
# Install MySQL client
sudo apt-get update
sudo apt-get install mysql-client

# Optional: Install kubectl (for K8s environments)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Optional: Install jq (for PVC monitoring)
sudo apt-get install jq
```

## Running in Different Environments

### WSL (Windows Subsystem for Linux)

The script is fully compatible with WSL. Make sure you have the MySQL client installed:

```bash
# Install MySQL client in WSL
sudo apt-get update
sudo apt-get install mysql-client

# Test connection to your MySQL server
mysql -h 2.3.4.5 -u root -p -e "SELECT 1;"

# Run the monitoring script
cd /path/to/percona_operator/percona/scripts/monitoring
./monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p
```

**WSL Notes:**
- The script will automatically check if `mysql` client is installed
- Storage monitoring (PVC) features require `kubectl` and `jq` (optional)
- Color output works in Windows Terminal, WSL Terminal, and most modern terminals
- The script uses standard bash features compatible with WSL's bash
- For complete WSL setup instructions, see: [WSL_SETUP.md](../../on-prem/WSL_SETUP.md)

### On-Prem / Local MySQL

When running on-prem or with a local MySQL instance, the script will monitor:
- MySQL cluster health and performance
- Memory and I/O statistics
- Connection and query metrics

Storage monitoring (PVC) is automatically skipped if `kubectl` is not available or not in a Kubernetes environment.

```bash
# On-prem example with local MySQL
./monitor-pxc-load-test.sh -h 127.0.0.1 -u root -p

# With custom interval
INTERVAL=10 ./monitor-pxc-load-test.sh -u root -p
```

### Kubernetes (EKS, On-Prem K8s)

When running in a Kubernetes environment with `kubectl` available, the script will additionally monitor:
- PVC capacity and usage for MySQL pods
- Storage class information
- PVC-to-Pod mappings
- Disk usage percentage with color-coded alerts

The script automatically detects the namespace from:
1. MySQL host FQDN (e.g., `mysql.default.svc.cluster.local`)
2. Current kubectl context namespace
3. Falls back to `default` namespace

```bash
# Kubernetes example (auto-detects namespace)
./monitor-pxc-load-test.sh -h mysql.percona.svc.cluster.local -u root -p

# Ensure kubectl is configured
kubectl config current-context
kubectl get pvc -n <your-namespace>
```

### Dashboard vs Scrolling Mode

**Dashboard Mode (Default):**
- Clears screen and refreshes in place (like `top` or `htop`)
- Clean, organized single-screen view
- Shows header with connection info and timestamp
- Automatically adapts to terminal width
- Best for real-time monitoring

**Scrolling Mode:**
- Traditional output that scrolls down
- Useful for logging or piping to files
- Enable with `--scroll` or `-s` flag
- Enable with `DASHBOARD_MODE=0` environment variable

```bash
# Dashboard mode (default)
./monitor-pxc-load-test.sh -u root -p

# Scrolling mode
./monitor-pxc-load-test.sh -u root -p --scroll

# Scrolling mode via environment variable
DASHBOARD_MODE=0 ./monitor-pxc-load-test.sh -u root -p
```

### Daemon Mode

The script runs as a daemon by default, continuously monitoring at the specified interval:

```bash
# Daemon mode (default) - runs until Ctrl+C
./monitor-pxc-load-test.sh -u root -p

# Custom refresh interval (10 seconds)
./monitor-pxc-load-test.sh -i 10 -u root -p

# Single run mode (no daemon)
./monitor-pxc-load-test.sh -i 0 -u root -p
```

When you press **Ctrl+C**, the script clears the screen, generates a comprehensive final report, and exits gracefully.

## Troubleshooting

### Script Exits Immediately / Connection Issues

If the script exits immediately or you see connection errors, enable **debug mode** to see detailed information:

```bash
# Enable debug mode to see what's happening
DEBUG=1 ./monitor-pxc-load-test.sh -h 2.3.4.5 -u root -p
```

Debug mode shows:
- MySQL client detection
- Connection parameters being used
- Full MySQL error messages
- Exit codes and detailed diagnostics

### Common Connection Issues

If you see `[ERROR] Cannot connect to MySQL`, the script shows the actual MySQL error. Here's how to diagnose:

```bash
# 1. Check if MySQL client is installed
mysql --version

# 2. Test connectivity to MySQL server
nc -zv 2.3.4.5 3306
# or
telnet 2.3.4.5 3306

# 3. Test MySQL connection manually
mysql -h 2.3.4.5 -P 3306 -u root -p -e "SELECT 1;"

# 4. Check MySQL error log on the server
tail -f /var/log/mysql/error.log
```

**Common Issues:**
1. **MySQL client not installed** - Install with: `sudo apt-get install mysql-client`
2. **MySQL server not running** - Check server status
3. **Firewall blocking port 3306** - Check firewall rules on both client and server
4. **Wrong password** - Verify credentials
5. **MySQL not accepting remote connections** - Check `bind-address` in my.cnf (should be `0.0.0.0` or specific IP)
6. **User not granted remote access** - Grant access: `GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY 'password';`

**Password Options:**
The script supports multiple ways to provide passwords (like MySQL client):
- `-p` alone: Prompts for password securely
- `-p PASSWORD`: Password with space
- `-pPASSWORD`: Password without space (MySQL style)
- `--password PASSWORD`: Long form with required argument

```bash
# Check if Performance Schema is enabled
mysql -u root -p -e "SHOW VARIABLES LIKE 'performance_schema';"

# Grant remote access if needed (run on MySQL server)
mysql -u root -p
CREATE USER 'root'@'%' IDENTIFIED BY 'yourpassword';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

### Performance Schema Disabled
Some queries require Performance Schema to be enabled:
```sql
-- Check if enabled
SHOW VARIABLES LIKE 'performance_schema';

-- Enable in my.cnf if needed
[mysqld]
performance_schema = ON
```

### Access Denied
Make sure your MySQL user has appropriate privileges:
```sql
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'monitor_user'@'%';
GRANT SELECT ON performance_schema.* TO 'monitor_user'@'%';
GRANT SELECT ON information_schema.* TO 'monitor_user'@'%';
GRANT SELECT ON sys.* TO 'monitor_user'@'%';
```

## Load Testing Checklist

- [ ] Start monitoring script before load testing
- [ ] Note baseline metrics (no load)
- [ ] Run load test gradually (increase concurrency)
- [ ] Monitor for flow control activation
- [ ] Watch for replication lag
- [ ] Check buffer pool hit rates
- [ ] Look for lock contention
- [ ] Generate final report after testing

## Interpreting Results

### Good Performance
- Flow control rarely activates
- Queue sizes stay at 0
- Buffer pool hit rate > 99%
- No lock waits
- Consistent response times

### Performance Issues
- Frequent flow control pauses
- Growing queue sizes
- Low buffer pool hit rates
- Lock waits increasing
- Response times degrading

### Cluster Issues
- Node status changes from "Synced"
- wsrep_ready goes OFF
- Cluster status changes from "Primary"
- Certification failures increasing

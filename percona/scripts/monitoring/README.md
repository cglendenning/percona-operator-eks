# PXC Load Testing Monitoring

This directory contains tools to monitor your Percona XtraDB Cluster (PXC) during load testing.

## Files

- `pxc-load-test-queries.sql` - Comprehensive SQL queries for manual monitoring
- `monitor-pxc-load-test.sh` - Automated monitoring script with real-time dashboard
- `README.md` - This documentation

## Quick Start

### Option 1: Automated Monitoring Script (Recommended)

```bash
# Monitor every 5 seconds with real-time output
./monitor-pxc-load-test.sh -u root -p

# Single report only (no continuous monitoring)
./monitor-pxc-load-test.sh -i 0 -u root -p

# Custom connection settings
./monitor-pxc-load-test.sh -h mysql-cluster.example.com -P 3307 -u admin -p
```

### Option 2: Manual SQL Queries

Connect to your PXC cluster and run queries from `pxc-load-test-queries.sql`:

```bash
mysql -h 127.0.0.1 -P 3306 -u root -p < pxc-load-test-queries.sql
```

## What to Monitor During Load Testing

### 🔴 Critical Alerts (Stop Testing)

1. **Cluster Status ≠ Primary** - Cluster has split-brain or lost quorum
2. **wsrep_ready = OFF** - Node not ready to process writes
3. **wsrep_flow_control_paused > 0** - Cluster is bottlenecked
4. **High Queue Sizes** - Replication falling behind

### 🟡 Performance Warnings

1. **Buffer Pool Hit Rate < 95%** - Memory pressure
2. **Lock Waits > 0** - Concurrency issues
3. **High Connection Count** - Connection pool exhaustion
4. **Slow Queries** - Performance degradation

### 🟢 Normal Operation

1. **Cluster Size = 3** - All nodes online
2. **Flow Control = 0** - No bottlenecks
3. **Queue Sizes = 0** - Replication in sync
4. **Buffer Pool Hit Rate > 99%** - Good cache efficiency

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

## Sample Output

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

## Troubleshooting

### Connection Issues
```bash
# Test MySQL connection
mysql -h 127.0.0.1 -P 3306 -u root -p -e "SELECT 1;"

# Check if Performance Schema is enabled
mysql -u root -p -e "SHOW VARIABLES LIKE 'performance_schema';"
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

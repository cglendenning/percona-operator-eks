# Connection Pool Monitor

A diagnostic CLI tool to observe HikariCP-like connection pool behavior when connecting to Percona XtraDB Cluster (PXC) through HAProxy or ProxySQL.

## Purpose

This tool helps identify connection issues during:
- Pod rolling updates
- Network partitions
- Proxy failovers
- Backend node failures

It shows the full connection path from application pool through proxy to PXC nodes, making it easy to compare behavior between HAProxy and ProxySQL.

## Build

```bash
cd connpool-monitor
go mod tidy
go build -o connpool-monitor .
```

## Usage

### HAProxy Mode (default)

```bash
./connpool-monitor \
  --proxy-host haproxy.percona.svc.cluster.local \
  --proxy-port 3306 \
  --proxy-user root \
  --proxy-password secretpass \
  --database mydb \
  --haproxy-stats-url http://haproxy.percona.svc.cluster.local:8404/stats \
  --pxc-nodes pxc-0.pxc.percona:3306,pxc-1.pxc.percona:3306,pxc-2.pxc.percona:3306
```

### ProxySQL Mode

```bash
./connpool-monitor --proxysql \
  --proxy-host proxysql.percona.svc.cluster.local \
  --proxy-port 6033 \
  --proxy-user root \
  --proxy-password secretpass \
  --database mydb \
  --proxysql-admin-host proxysql.percona.svc.cluster.local \
  --proxysql-admin-port 6032 \
  --proxysql-admin-user admin \
  --proxysql-admin-password admin \
  --pxc-nodes pxc-0.pxc.percona:3306,pxc-1.pxc.percona:3306,pxc-2.pxc.percona:3306
```

## Flags

### Connection Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--proxy-host` | localhost | HAProxy or ProxySQL host |
| `--proxy-port` | 3306 | Proxy MySQL port |
| `--proxy-user` | root | MySQL user |
| `--proxy-password` | | MySQL password |
| `--database` | test | Database name |

### HAProxy Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--haproxy-stats-url` | http://localhost:8404/stats | HAProxy stats endpoint |
| `--haproxy-stats-user` | | Stats basic auth user |
| `--haproxy-stats-password` | | Stats basic auth password |

### ProxySQL Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--proxysql` | false | Enable ProxySQL mode |
| `--proxysql-admin-host` | localhost | ProxySQL admin interface host |
| `--proxysql-admin-port` | 6032 | ProxySQL admin port |
| `--proxysql-admin-user` | admin | Admin interface user |
| `--proxysql-admin-password` | admin | Admin interface password |

### PXC Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--pxc-nodes` | | Comma-separated PXC nodes (e.g., node1:3306,node2:3306) |
| `--pxc-user` | (proxy-user) | Direct PXC access user |
| `--pxc-password` | (proxy-password) | Direct PXC access password |

### Pool Flags (HikariCP-like)
| Flag | Default | Description |
|------|---------|-------------|
| `--pool-size` | 10 | Maximum pool size (maximumPoolSize) |
| `--min-idle` | 2 | Minimum idle connections (minimumIdle) |
| `--max-lifetime` | 30m | Connection max lifetime (maxLifetime) |
| `--idle-timeout` | 10m | Idle connection timeout (idleTimeout) |
| `--connection-timeout` | 30s | Connection acquisition timeout |
| `--validation-interval` | 5s | Connection validation frequency |

### Workload Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--read-qps` | 10 | Read queries per second |
| `--write-qps` | 2 | Write queries per second |

## Dashboard Sections

### Connection Pool Status
Shows HikariCP-equivalent metrics:
- Pool Size (open/max connections)
- In Use / Idle connections
- Wait count and duration
- Connections closed due to max-idle or max-lifetime
- Read/Write totals with failure counts
- Average latencies

### HAProxy Backend Status
When in HAProxy mode:
- Backend server names and addresses
- UP/DOWN/MAINT status
- Current connections vs max
- Health check status
- Time since last status change

### ProxySQL Status
When in ProxySQL mode (`--proxysql`):
- MySQL server hostgroups, status, weights
- Connection pool per-server stats
- Used/Free/OK/Error connection counts
- Query counts and latencies

### PXC Cluster Status
Direct node monitoring:
- wsrep state (Synced/Donor/Joiner)
- Cluster status and size
- Ready status
- Flow control status
- Receive/Send queue depths
- Active connections per node

### Recent Connection Errors
Captures and displays:
- Timestamp
- Operation type (read/write/connect)
- Target node (if known)
- Error message

## Testing Pod Rolling Updates

1. Start the monitor targeting your cluster
2. In another terminal, trigger a rolling update:
   ```bash
   kubectl rollout restart statefulset/pxc
   ```
3. Observe error patterns and recovery behavior

## Comparing HAProxy vs ProxySQL

Run two instances simultaneously:

Terminal 1 (HAProxy):
```bash
./connpool-monitor --proxy-host haproxy:3306 ...
```

Terminal 2 (ProxySQL):
```bash
./connpool-monitor --proxysql --proxy-host proxysql:6033 ...
```

Key differences to observe:
- Connection error rates during failover
- Time to detect backend changes
- Connection reuse patterns
- Query routing behavior (ProxySQL can route reads/writes separately)

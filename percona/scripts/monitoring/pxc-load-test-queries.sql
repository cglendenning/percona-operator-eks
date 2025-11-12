-- =============================================================================
-- Percona XtraDB Cluster (PXC) Load Testing Monitoring Queries
-- Run these queries in mysql client during load testing to monitor cluster health
-- =============================================================================

-- =============================================================================
-- CLUSTER STATUS QUERIES (Run on any node)
-- =============================================================================

-- 1. GALERA CLUSTER STATUS - Overall cluster health
SHOW GLOBAL STATUS LIKE 'wsrep_%';
-- Key metrics to watch:
-- - wsrep_cluster_size: Should be 3 (number of nodes)
-- - wsrep_ready: Should be ON
-- - wsrep_cluster_status: Should be Primary
-- - wsrep_connected: Should be ON

-- 2. GALERA CLUSTER MEMBERS - See all nodes in cluster
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME LIKE 'wsrep_node_%'
   OR VARIABLE_NAME LIKE 'wsrep_cluster_%';

-- 3. NODE SYNCHRONIZATION STATUS
SELECT
    node_index,
    node_uuid,
    name,
    address,
    state_uuid,
    status,
    size,
    local_index,
    name
FROM information_schema.wsrep_cluster_members
ORDER BY node_index;

-- 4. GALERA FLOW CONTROL - Critical for performance monitoring
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'wsrep_flow_control_%';
-- wsrep_flow_control_paused: If > 0, cluster is flow-controlled (bottleneck)
-- wsrep_flow_control_sent: Number of flow control messages sent

-- =============================================================================
-- QUEUE MONITORING - Look for bottlenecks
-- =============================================================================

-- 5. GALERA QUEUE SIZES - Monitor replication queues
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'wsrep_%queue%'
   OR VARIABLE_NAME LIKE 'wsrep_%cert%';
-- wsrep_local_recv_queue: Messages waiting to be applied
-- wsrep_local_send_queue: Messages waiting to be sent
-- wsrep_cert_deps_distance: Certification dependency distance

-- 6. THREAD POOL STATUS (if using thread pool)
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'threadpool%';

-- =============================================================================
-- INDIVIDUAL NODE PERFORMANCE (Run on each node)
-- =============================================================================

-- 7. CONNECTIONS AND THREADS - Monitor load
SELECT
    'Max Connections' as metric,
    @@max_connections as value
UNION ALL
SELECT
    'Current Connections',
    COUNT(*)
FROM information_schema.processlist
UNION ALL
SELECT
    'Active Threads',
    COUNT(*)
FROM performance_schema.threads
WHERE PROCESSLIST_STATE IS NOT NULL
UNION ALL
SELECT
    'Running Threads',
    COUNT(*)
FROM performance_schema.threads
WHERE PROCESSLIST_STATE = 'Running';

-- 8. RUNNING QUERIES - See what's executing
SELECT
    ID,
    USER,
    HOST,
    DB,
    COMMAND,
    TIME,
    STATE,
    INFO
FROM information_schema.processlist
WHERE COMMAND != 'Sleep'
    AND TIME > 1
ORDER BY TIME DESC
LIMIT 10;

-- 9. SLOW QUERIES - Performance bottlenecks
SELECT
    sql_text,
    exec_count,
    avg_timer_wait/1000000000 as avg_time_sec,
    max_timer_wait/1000000000 as max_time_sec,
    sum_timer_wait/1000000000 as total_time_sec
FROM performance_schema.events_statements_summary_by_digest
WHERE avg_timer_wait > 1000000000  -- > 1 second average
ORDER BY avg_timer_wait DESC
LIMIT 10;

-- =============================================================================
-- INNODB PERFORMANCE METRICS
-- =============================================================================

-- 10. INNODB BUFFER POOL STATUS - Memory usage
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'Innodb_buffer_pool_%'
    AND VARIABLE_NAME IN (
        'Innodb_buffer_pool_pages_total',
        'Innodb_buffer_pool_pages_free',
        'Innodb_buffer_pool_pages_data',
        'Innodb_buffer_pool_pages_dirty',
        'Innodb_buffer_pool_hit_rate'
    );

-- 11. INNODB LOCKS AND WAITS - Concurrency issues
SELECT
    'Lock Waits' as metric,
    COUNT(*) as value
FROM information_schema.innodb_lock_waits
UNION ALL
SELECT
    'Lock Wait Time',
    SUM(wait_age) / 1000  -- milliseconds
FROM information_schema.innodb_lock_waits
UNION ALL
SELECT
    'Deadlocks',
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Innodb_deadlocks';

-- 12. INNODB TRANSACTIONS - Active transactions
SELECT
    trx_id,
    trx_state,
    trx_started,
    trx_requested_lock_id,
    trx_wait_started,
    trx_weight,
    trx_mysql_thread_id,
    trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started DESC
LIMIT 5;

-- =============================================================================
-- SYSTEM RESOURCE MONITORING
-- =============================================================================

-- 13. MEMORY USAGE - Monitor memory pressure
SELECT
    'InnoDB Buffer Pool Size (MB)' as metric,
    @@innodb_buffer_pool_size / 1024 / 1024 as value
UNION ALL
SELECT
    'Current Memory Usage (MB)',
    (SELECT SUM(current_alloc)
     FROM sys.memory_by_thread_by_current_bytes
     WHERE thread_id IN (
         SELECT thread_id
         FROM performance_schema.threads
         WHERE PROCESSLIST_STATE IS NOT NULL
     )) / 1024 / 1024
UNION ALL
SELECT
    'Total Memory Allocated (MB)',
    (SELECT SUM(current_alloc)
     FROM sys.memory_by_thread_by_current_bytes) / 1024 / 1024;

-- 14. I/O STATISTICS - Disk performance
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'Innodb_data_%'
    AND VARIABLE_NAME IN (
        'Innodb_data_reads',
        'Innodb_data_writes',
        'Innodb_data_read',
        'Innodb_data_written'
    );

-- =============================================================================
-- PXC-SPECIFIC PERFORMANCE METRICS
-- =============================================================================

-- 15. GALERA REPLICATION LAG - Monitor sync status
SELECT
    node_index,
    name,
    address,
    last_committed,
    queued_after
FROM information_schema.wsrep_cluster_members
ORDER BY node_index;

-- 16. CERTIFICATION FAILURES - Replication conflicts
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'wsrep_cert%';
-- wsrep_cert_failures: Number of certification failures (conflicts)

-- 17. GALERA CACHE EFFICIENCY
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME LIKE 'wsrep_gcache%';

-- =============================================================================
-- PERFORMANCE SCHEMA ENABLEMENT CHECK
-- =============================================================================

-- 18. VERIFY PERFORMANCE SCHEMA IS ENABLED
SELECT
    VARIABLE_NAME,
    VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME = 'performance_schema';
-- Should be ON for detailed monitoring

-- 19. TOP WAITING EVENTS - Where time is spent
SELECT
    EVENT_NAME,
    COUNT_STAR as count,
    SUM_TIMER_WAIT / 1000000000 as total_time_sec,
    AVG_TIMER_WAIT / 1000000000 as avg_time_sec
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE EVENT_NAME NOT LIKE 'idle'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- =============================================================================
-- LOAD TESTING DASHBOARD QUERY
-- =============================================================================

-- 20. COMPREHENSIVE CLUSTER HEALTH DASHBOARD
SELECT
    'CLUSTER STATUS' as section,
    'Cluster Size' as metric,
    VARIABLE_VALUE as value,
    'Should be 3' as expected
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'wsrep_cluster_size'
UNION ALL
SELECT
    'CLUSTER STATUS',
    'Cluster Status',
    VARIABLE_VALUE,
    'Should be Primary'
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'wsrep_cluster_status'
UNION ALL
SELECT
    'CLUSTER STATUS',
    'Flow Control Paused',
    VARIABLE_VALUE,
    'Should be 0.000000'
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'wsrep_flow_control_paused'
UNION ALL
SELECT
    'PERFORMANCE',
    'Active Connections',
    COUNT(*),
    'Monitor vs max_connections'
FROM information_schema.processlist
UNION ALL
SELECT
    'PERFORMANCE',
    'Running Queries',
    COUNT(*),
    'Should be reasonable'
FROM information_schema.processlist
WHERE COMMAND NOT IN ('Sleep', 'Connect')
UNION ALL
SELECT
    'INNODB',
    'Buffer Pool Hit Rate',
    ROUND(VARIABLE_VALUE, 2),
    'Should be > 95%'
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Innodb_buffer_pool_hit_rate'
UNION ALL
SELECT
    'INNODB',
    'Lock Waits',
    COUNT(*),
    'Should be 0'
FROM information_schema.innodb_lock_waits
UNION ALL
SELECT
    'GALERA',
    'Local Recv Queue',
    VARIABLE_VALUE,
    'Should be 0'
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'wsrep_local_recv_queue'
UNION ALL
SELECT
    'GALERA',
    'Local Send Queue',
    VARIABLE_VALUE,
    'Should be 0'
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'wsrep_local_send_queue';

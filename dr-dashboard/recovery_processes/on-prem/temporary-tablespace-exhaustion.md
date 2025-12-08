# Temporary Tablespace Exhaustion Recovery Process

This scenario covers disk exhaustion caused by MySQL temporary tables and files, which are created during query execution for sorts, joins, GROUP BY operations, and derived tables.

## Important: The "Phantom Disk Full" Problem

A key characteristic of this scenario is that **temp files are automatically cleaned up when the query fails**. This creates a confusing situation:

1. Alert fires: "Disk usage exceeded 90%"
2. You log in to investigate
3. Disk shows 40% usage - plenty of free space
4. You think the alert was a false positive

**This is NOT a false positive.** A query created massive temp files, filled the disk, failed, and MySQL automatically cleaned up the temp files. The problem will recur when the query runs again.

## Detection Signals

- Disk usage alerts that show high usage, then suddenly drop
- Queries failing with "No space left on device" mid-execution
- Queries that previously worked suddenly failing
- Disk usage spikes correlated with specific query patterns or scheduled jobs
- Error log entries showing temp file creation failures

## Primary Recovery Method

1. **Confirm temp space was the issue**
   ```bash
   # Check current disk usage (may appear normal now)
   kubectl exec -n <namespace> <pod> -- df -h /var/lib/mysql
   
   # Check tmpdir location
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SHOW VARIABLES LIKE 'tmpdir';"
   
   # Check temp directory usage
   kubectl exec -n <namespace> <pod> -- du -sh /tmp 2>/dev/null
   kubectl exec -n <namespace> <pod> -- ls -la /tmp/
   
   # Look for evidence in error log
   kubectl logs -n <namespace> <pod> --tail=500 | grep -i "temp\|tmp\|space"
   
   # Check for recent query failures
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SHOW GLOBAL STATUS LIKE 'Created_tmp%';"
   ```

2. **Find the problematic query**
   ```bash
   # Check slow query log for recent large queries
   kubectl exec -n <namespace> <pod> -- tail -100 /var/lib/mysql/slow-query.log
   
   # Look for currently running queries creating temp tables
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, 
            SUBSTRING(INFO, 1, 200) as query
     FROM information_schema.PROCESSLIST 
     WHERE STATE LIKE '%tmp%' OR STATE LIKE '%sort%' OR STATE LIKE '%Creating%'
     ORDER BY TIME DESC;"
   
   # Check for queries with filesort or temp table usage
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT DIGEST_TEXT, COUNT_STAR, 
            SUM_CREATED_TMP_DISK_TABLES, SUM_CREATED_TMP_TABLES,
            SUM_SORT_MERGE_PASSES
     FROM performance_schema.events_statements_summary_by_digest
     WHERE SUM_CREATED_TMP_DISK_TABLES > 0
     ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC
     LIMIT 10;"
   ```

3. **Kill problematic queries if currently running**
   ```bash
   # List long-running queries that might be creating temp tables
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT ID, USER, TIME, STATE, INFO 
     FROM information_schema.PROCESSLIST 
     WHERE COMMAND != 'Sleep' 
       AND (STATE LIKE '%sort%' OR STATE LIKE '%tmp%' OR TIME > 300)
     ORDER BY TIME DESC;"
   
   # Kill specific query
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "KILL <query_id>;"
   ```

4. **Increase temp table limits to keep more in memory**
   ```bash
   # Check current temp table settings
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SHOW VARIABLES WHERE Variable_name IN 
       ('tmp_table_size', 'max_heap_table_size', 'temptable_max_ram');"
   
   # Increase tmp_table_size (e.g., to 256MB)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SET GLOBAL tmp_table_size = 268435456;"
   
   # max_heap_table_size must also be increased (uses smaller of the two)
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SET GLOBAL max_heap_table_size = 268435456;"
   
   # For MySQL 8.0+, also consider temptable_max_ram
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SET GLOBAL temptable_max_ram = 1073741824;"  # 1GB
   ```

5. **Monitor for recurrence**
   ```bash
   # Watch disk usage while running suspected query
   kubectl exec -n <namespace> <pod> -- watch -n1 'df -h /var/lib/mysql; ls -lh /tmp/'
   
   # Monitor temp table creation in real-time
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     SELECT * FROM performance_schema.global_status 
     WHERE VARIABLE_NAME LIKE 'Created_tmp%';"
   ```

## Alternate/Fallback Method

1. **Restart MySQL to clear all temp files**
   ```bash
   # If queries are stuck and temp files can't be identified
   kubectl delete pod -n <namespace> <pod>
   
   # Wait for pod to restart
   kubectl wait --for=condition=Ready pod/<pod> -n <namespace> --timeout=300s
   ```

2. **Optimize the problematic query**
   ```bash
   # Once you identify the query, analyze it
   kubectl exec -n <namespace> <pod> -- mysql -uroot -p<pass> -e "
     EXPLAIN FORMAT=TREE <problematic_query>;"
   
   # Look for:
   # - "Using filesort" - add appropriate index
   # - "Using temporary" - restructure query or add index
   # - Large derived tables - consider materializing as actual table
   # - GROUP BY without index - add covering index
   ```

3. **Add dedicated tmpdir on separate volume**
   ```bash
   # In PerconaXtraDBCluster CR, add configuration for separate tmpdir
   # This isolates temp file usage from data directory
   
   # Example in pxc configuration:
   # configuration: |
   #   [mysqld]
   #   tmpdir=/mnt/temp
   ```

## Query Patterns That Cause Temp Space Exhaustion

- **Large GROUP BY operations** without supporting indexes
- **ORDER BY on non-indexed columns** with large result sets
- **JOINs between large tables** without proper indexes
- **Subqueries in FROM clause** (derived tables)
- **UNION operations** on large datasets
- **SELECT DISTINCT** on large result sets
- **Window functions** over large partitions

## Prevention

1. **Add indexes to support common GROUP BY and ORDER BY operations**
2. **Review and optimize queries that create temp tables**
3. **Set appropriate tmp_table_size and max_heap_table_size**
4. **Consider separate tmpdir volume for isolation**
5. **Add monitoring for Created_tmp_disk_tables metric**

## Recovery Targets

- **Restore Time Objective**: 15 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 15-30 minutes

## Expected Data Loss

None (temporary tables contain no persistent data)

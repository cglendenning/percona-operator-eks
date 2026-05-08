# Kubernetes objects for ConfigMap-driven PMM alert provisioning for PXC clusters.
#
# Build/app image separately with Dockerfile in this directory:
#   docker buildx build --load -t pxc-pmm-alerts-controller:latest .
# Apply manifests (pure Nix, no nixpkgs: avoids multi-GiB Darwin stdenv on nix-build):
#   nix-build pxc-pmm-alerts.nix -A k8sManifest && kubectl apply -f result  # result is a v1/List JSON
#
# Optional: `nix-build … --argstr alertEnv prod --argstr alertRoute opsgenie`

{
  alertEnv ? "dev",
  alertRoute ? "pagerduty",
}:

let
  namespace = "pmm";
  serviceAccountName = "pxc-pmm-alerts-sa";
  roleName = "pxc-pmm-alerts-role";
  # Per-namespace Role/RoleBinding name on each PXC namespace (read PerconaXtraDBCluster CRs,
  # plus pods/pvcs to derive operator-view metrics that PMM-scraped mysql_*/node_* cannot see).
  watchRoleName = "pxc-pmm-alerts-watch";
  deploymentName = "pxc-pmm-alerts-controller";
  rulesConfigMapName = "pxc-pmm-alert-rules";
  # Helm chart `percona/pmm` creates this secret with generated admin password.
  credentialsSecret = "pmm-secret";

  # Namespaces that contain PerconaXtraDBCluster CRs. The controller lists pxc CRs, pods, and PVCs
  # in each, derives gauges (pxc_cluster_ready, pxc_cluster_state, pxc_pvc_pending, pxc_pod_ready),
  # and pushes them to PMM via VictoriaMetrics import. Add a namespace here when you deploy a new
  # pxc cluster; the manifest will emit a Role + RoleBinding scoped to that namespace only.
  pxcWatchNamespaces = [ "percona" ];

  /* Each object is POSTed to PMM `POST /v1/alerting/rules` (same pattern as `modules/projects/pmm/alerts.nix`).
     - Template rule: built-in PMM template `pmm_mysql_down`.
     - Custom expr rules: PromQL `expr` + `group` + `for` + labels (no template).
     Placeholder `__MYSQL_FOLDER_UID__` is replaced at runtime by the controller if present in JSON strings. */
  alertRules = [
    {
      name = "No MySQL Instances Monitored";
      group = "expression";
      expr = "absent(mysql_global_status_uptime)";
      for = "120s";
      no_data_state = "OK";
      custom_labels = {
        source = "pxc-pmm";
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PMM Server Data Volume Space Warning";
      group = "expression";
      expr = "(node_filesystem_avail_bytes{mountpoint=\"/srv\"} / node_filesystem_size_bytes{mountpoint=\"/srv\"}) * 100 < 30";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PMM Server Data Volume Space Critical";
      group = "expression";
      expr = "(node_filesystem_avail_bytes{mountpoint=\"/srv\"} / node_filesystem_size_bytes{mountpoint=\"/srv\"}) * 100 < 20";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Disk Usage Warning";
      group = "expression";
      expr = "((node_filesystem_avail_bytes{mountpoint=\"/var/lib/mysql\"} / node_filesystem_size_bytes{mountpoint=\"/var/lib/mysql\"}) * 100 < 30) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Disk Usage Critical";
      group = "expression";
      expr = "((node_filesystem_avail_bytes{mountpoint=\"/var/lib/mysql\"} / node_filesystem_size_bytes{mountpoint=\"/var/lib/mysql\"}) * 100 < 20) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC mysql_up Warning";
      group = "expression";
      expr = "sum by (service_name)(mysql_up == 0) > 0";
      for = "3m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC mysql_up Critical";
      group = "expression";
      expr = "sum by (service_name)(mysql_up == 0) >= 2";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Cluster Size Warning";
      group = "expression";
      expr = "max by (service_name)(mysql_global_status_wsrep_cluster_size) < 3";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Cluster Size Critical";
      group = "expression";
      expr = "max by (service_name)(mysql_global_status_wsrep_cluster_size) < 2";
      for = "2m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC CPU Busy Warning";
      group = "expression";
      expr = "(100 * (1 - avg by (service_name) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))) > 85) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC CPU Busy Critical";
      group = "expression";
      expr = "(100 * (1 - avg by (service_name) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))) > 95) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC CPU Steal Warning";
      group = "expression";
      expr = "(100 * avg by (service_name) (rate(node_cpu_seconds_total{mode=\"steal\"}[5m])) > 5) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC CPU Steal Critical";
      group = "expression";
      expr = "(100 * avg by (service_name) (rate(node_cpu_seconds_total{mode=\"steal\"}[5m])) > 10) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Memory Available Warning";
      group = "expression";
      expr = "(((100 * (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) < 8) and (((rate(node_vmstat_pswpin[5m]) + rate(node_vmstat_pswpout[5m])) > 10) or (rate(node_vmstat_pgmajfault[5m]) > 50))) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Memory Available Critical";
      group = "expression";
      expr = "(((100 * (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) < 5) and (((rate(node_vmstat_pswpin[5m]) + rate(node_vmstat_pswpout[5m])) > 25) or (rate(node_vmstat_pgmajfault[5m]) > 200))) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Swap Activity Warning";
      group = "expression";
      expr = "(sum by (service_name) (rate(node_vmstat_pswpin[5m]) + rate(node_vmstat_pswpout[5m])) > 10) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Swap Activity Critical";
      group = "expression";
      expr = "(sum by (service_name) (rate(node_vmstat_pswpin[5m]) + rate(node_vmstat_pswpout[5m])) > 50) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Host OOM Kills Critical";
      group = "expression";
      expr = "(sum by (service_name) (increase(node_vmstat_oom_kill[10m])) > 0) and on(service_name) (max by (service_name) (mysql_global_status_uptime) > 0)";
      for = "1m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "HAProxy Down Critical";
      group = "expression";
      expr = "min by (service_name) (haproxy_up) < 1";
      for = "2m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "HAProxy Backends Down Critical";
      group = "expression";
      expr = "sum by (service_name, proxy) (haproxy_server_up) == 0";
      for = "1m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "HAProxy Backend Capacity Degraded Warning";
      group = "expression";
      expr = "(sum by (service_name, proxy) (haproxy_server_up) / clamp_min(count by (service_name, proxy) (haproxy_server_up), 1)) < 1";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Binlog Disabled Critical";
      group = "expression";
      expr = "max by (service_name) (mysql_global_variables_log_bin) < 1";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Binlog Cache Disk Spill Warning";
      group = "expression";
      expr = "(sum by (service_name) (rate(mysql_global_status_binlog_cache_disk_use[15m])) / clamp_min(sum by (service_name) (rate(mysql_global_status_binlog_cache_use[15m])), 1)) > 0.05";
      for = "15m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Binlog Cache Disk Spill Critical";
      group = "expression";
      expr = "(sum by (service_name) (rate(mysql_global_status_binlog_cache_disk_use[15m])) / clamp_min(sum by (service_name) (rate(mysql_global_status_binlog_cache_use[15m])), 1)) > 0.2";
      for = "15m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Binlog Statement Cache Disk Spill Warning";
      group = "expression";
      expr = "(sum by (service_name) (rate(mysql_global_status_binlog_stmt_cache_disk_use[15m])) / clamp_min(sum by (service_name) (rate(mysql_global_status_binlog_stmt_cache_use[15m])), 1)) > 0.1";
      for = "15m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Binlog Statement Cache Disk Spill Critical";
      group = "expression";
      expr = "(sum by (service_name) (rate(mysql_global_status_binlog_stmt_cache_disk_use[15m])) / clamp_min(sum by (service_name) (rate(mysql_global_status_binlog_stmt_cache_use[15m])), 1)) > 0.3";
      for = "15m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "Galera Flow Control Warning";
      group = "expression";
      expr = "avg by (service_name)(rate(mysql_global_status_wsrep_flow_control_paused_ns[5m]) / 1e9) > 0.3";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "Galera Flow Control Critical";
      group = "expression";
      expr = "avg by (service_name)(rate(mysql_global_status_wsrep_flow_control_paused_ns[5m]) / 1e9) > 0.6";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    # Async / traditional replication (targets with mysql_slave_status_* / replica_* only; PXC primaries without a replica channel do not match).
    {
      name = "MySQL Async Replication Down Warning";
      group = "expression";
      expr = "max by (service_name, channel) ( (mysql_slave_status_slave_io_running == bool 0) or (mysql_slave_status_slave_sql_running == bool 0) or (mysql_slave_status_replica_io_running == bool 0) or (mysql_slave_status_replica_sql_running == bool 0) ) > 0";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "MySQL Async Replication Down Critical";
      group = "expression";
      expr = "max by (service_name, channel) ( (mysql_slave_status_slave_io_running == bool 0) or (mysql_slave_status_slave_sql_running == bool 0) or (mysql_slave_status_replica_io_running == bool 0) or (mysql_slave_status_replica_sql_running == bool 0) ) > 0";
      for = "15m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "MySQL Async Replication Lag Warning";
      group = "expression";
      expr = "( max by (service_name, channel) ( mysql_slave_status_seconds_behind_master or mysql_slave_status_seconds_behind_source ) > 60 ) and on (service_name, channel) ( (max by (service_name, channel) (mysql_slave_status_slave_io_running or mysql_slave_status_replica_io_running)) == 1 ) and on (service_name, channel) ( (max by (service_name, channel) (mysql_slave_status_slave_sql_running or mysql_slave_status_replica_sql_running)) == 1 )";
      for = "1m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "MySQL Async Replication Lag Critical";
      group = "expression";
      expr = "( max by (service_name, channel) ( mysql_slave_status_seconds_behind_master or mysql_slave_status_seconds_behind_source ) > 300 ) and on (service_name, channel) ( (max by (service_name, channel) (mysql_slave_status_slave_io_running or mysql_slave_status_replica_io_running)) == 1 ) and on (service_name, channel) ( (max by (service_name, channel) (mysql_slave_status_slave_sql_running or mysql_slave_status_replica_sql_running)) == 1 )";
      for = "1m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    # Operator-view alerts: derived from PerconaXtraDBCluster CR status, not from mysqld scrapes.
    # The controller pushes pxc_cluster_*/pxc_pod_*/pxc_pvc_* gauges to VictoriaMetrics each cycle.
    # Together with the heartbeat alert below, these close the gap when PMM-scraped mysql_up,
    # node_*, or haproxy_up cannot fire (e.g. pod stuck Pending, cluster paused, error reconcile).
    {
      name = "PXC Alert Controller Heartbeat Stale Critical";
      group = "expression";
      # If this fires, every other PXC CR-level alert below is potentially silent: the
      # controller is not pushing operator-view gauges. Treat as ground truth for alerting health.
      expr = "(time() - max(pxc_pmm_alerts_collector_heartbeat_seconds)) > 300 or absent(pxc_pmm_alerts_collector_heartbeat_seconds)";
      for = "2m";
      no_data_state = "Alerting";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Cluster Not Ready Critical";
      group = "expression";
      # status.state != "ready" for 5 minutes -> page. Covers the gap where mysqld is up on the
      # survivors but the operator considers the cluster degraded (failed reconcile, missing
      # replica, immutable spec change, TLS rotation stuck).
      expr = "max by (cluster, namespace) (pxc_cluster_ready) == 0";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Cluster Error State Critical";
      group = "expression";
      # status.state == "error" is sticky in the operator and means reconcile gave up.
      expr = "max by (cluster, namespace) (pxc_cluster_state{state=\"error\"}) == 1";
      for = "1m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Cluster Stuck Initializing Critical";
      group = "expression";
      expr = "max by (cluster, namespace) (pxc_cluster_state{state=~\"initializing|applying-changes\"}) == 1";
      for = "15m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Cluster Paused Warning";
      group = "expression";
      expr = "max by (cluster, namespace) (pxc_cluster_paused) == 1";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Replicas Below Desired Critical";
      group = "expression";
      # Operator-reported ready < size for too long means at least one pxc replica is missing
      # (Pending pod, evicted, OOMKilled before mysqld could come up). PMM-side mysql_up cannot
      # detect this when the unhealthy pod never produces a series.
      expr = "(max by (cluster, namespace) (pxc_pxc_size) - max by (cluster, namespace) (pxc_pxc_ready)) > 0";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC HAProxy Replicas Below Desired Warning";
      group = "expression";
      expr = "(max by (cluster, namespace) (pxc_haproxy_size) - max by (cluster, namespace) (pxc_haproxy_ready)) > 0";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC PVC Unbound Critical";
      group = "expression";
      # Bare-metal / cloud volume binding failures keep pxc pods Pending and silently exclude
      # them from every PMM-scraped MySQL alert.
      expr = "max by (cluster, namespace, pvc) (pxc_pvc_pending) == 1";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Pod Not Ready Warning";
      group = "expression";
      expr = "max by (cluster, namespace, pod) (pxc_pod_ready{role=\"pxc\"}) == 0";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Pod Not Ready Critical";
      group = "expression";
      expr = "max by (cluster, namespace, pod) (pxc_pod_ready{role=\"pxc\"}) == 0";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Operator Generation Drift Warning";
      group = "expression";
      # observedGeneration < generation for too long -> operator hasn't acked the latest spec.
      expr = "(max by (cluster, namespace) (pxc_cluster_generation) - max by (cluster, namespace) (pxc_cluster_observed_generation)) > 0";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = alertRoute;
        env = alertEnv;
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
  ];

  # Per-namespace Role granting the controller's ServiceAccount the minimum verbs to derive
  # operator-view metrics (list/get pods+pvcs and pxc CRs) in each pxc namespace. Built once per
  # entry in `pxcWatchNamespaces` so adding a new pxc namespace requires only one list edit.
  pxcWatchRbacObjects = builtins.concatMap (ns: [
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = watchRoleName;
        namespace = ns;
      };
      rules = [
        {
          apiGroups = [ "pxc.percona.com" ];
          resources = [ "perconaxtradbclusters" ];
          verbs = [ "get" "list" "watch" ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "pods" "persistentvolumeclaims" ];
          verbs = [ "get" "list" "watch" ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = watchRoleName;
        namespace = ns;
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = serviceAccountName;
          inherit namespace;
        }
      ];
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = watchRoleName;
      };
    }
  ]) pxcWatchNamespaces;

  objects = [
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = serviceAccountName;
        inherit namespace;
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = roleName;
        inherit namespace;
      };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "configmaps" ];
          resourceNames = [ rulesConfigMapName ];
          verbs = [ "get" ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          resourceNames = [ credentialsSecret ];
          verbs = [ "get" ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = roleName;
        inherit namespace;
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = serviceAccountName;
          inherit namespace;
        }
      ];
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = roleName;
      };
    }
    {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = rulesConfigMapName;
        inherit namespace;
      };
      data = {
        "rules.json" = builtins.toJSON alertRules;
      };
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = deploymentName;
        inherit namespace;
      };
      spec = {
        replicas = 1;
        selector.matchLabels.app = deploymentName;
        template = {
          metadata.labels.app = deploymentName;
          spec = {
            serviceAccountName = serviceAccountName;
            containers = [
              {
                name = "controller";
                image = "pxc-pmm-alerts-controller:latest";
                imagePullPolicy = "IfNotPresent";
                env = [
                  {
                    name = "ALERT_RULES_NAMESPACE";
                    valueFrom.fieldRef.fieldPath = "metadata.namespace";
                  }
                  { name = "ALERT_RULES_CONFIGMAP"; value = rulesConfigMapName; }
                  { name = "ALERT_RULES_KEY"; value = "rules.json"; }
                  { name = "PMM_URL"; value = "https://monitoring-service.pmm.svc.cluster.local"; }
                  { name = "RULE_GROUP_NAME"; value = "template"; }
                  { name = "EXPR_RULE_BATCH_GROUP"; value = "expression"; }
                  { name = "SYNC_INTERVAL_MS"; value = "60000"; }
                  { name = "PXC_COLLECT_INTERVAL_MS"; value = "30000"; }
                  { name = "PXC_WATCH_NAMESPACES"; value = builtins.concatStringsSep "," pxcWatchNamespaces; }
                  { name = "PMM_REQUEST_TIMEOUT_MS"; value = "15000"; }
                  { name = "PMM_INSECURE_TLS"; value = "true"; }
                  { name = "PMM_USER"; value = "admin"; }
                  {
                    name = "PMM_PASSWORD";
                    valueFrom.secretKeyRef = {
                      name = credentialsSecret;
                      key = "PMM_ADMIN_PASSWORD";
                    };
                  }
                ];
              }
            ];
          };
        };
      };
    }
  ];

  jsonList = {
    apiVersion = "v1";
    kind = "List";
    items = objects ++ pxcWatchRbacObjects;
  };
  jsonPath = builtins.toFile "pxc-pmm-alerts-body.json" (builtins.toJSON jsonList);
  manifest = derivation {
    name = "pxc-pmm-alerts-k8s.json";
    system = builtins.currentSystem;
    builder = "/bin/sh";
    args = [ "-c" "/bin/cp ${jsonPath} $out" ];
  };
in
{
  k8sManifest = manifest;
  default = manifest;
}

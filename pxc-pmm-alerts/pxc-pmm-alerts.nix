# Kubernetes objects for ConfigMap-driven PMM alert provisioning for PXC clusters.
#
# Build/app image separately with Dockerfile in this directory:
#   docker buildx build --load -t pxc-pmm-alerts-controller:latest .
# Apply manifests (pure Nix, no nixpkgs: avoids multi-GiB Darwin stdenv on nix-build):
#   nix-build pxc-pmm-alerts.nix -A k8sManifest && kubectl apply -f result  # result is a v1/List JSON

let
  namespace = "pmm";
  serviceAccountName = "pxc-pmm-alerts-sa";
  roleName = "pxc-pmm-alerts-role";
  deploymentName = "pxc-pmm-alerts-controller";
  rulesConfigMapName = "pxc-pmm-alert-rules";
  # Helm chart `percona/pmm` creates this secret with generated admin password.
  credentialsSecret = "pmm-secret";

  /* Each object is POSTed to PMM `POST /v1/alerting/rules` (same pattern as `modules/projects/pmm/alerts.nix`).
     - Template rule: built-in PMM template `pmm_mysql_down`.
     - Custom expr rules: PromQL `expr` + `group` + `for` + labels (no template).
     Placeholder `__MYSQL_FOLDER_UID__` is replaced at runtime by the controller if present in JSON strings. */
  alertRules = [
    {
      folder_uid = "__MYSQL_FOLDER_UID__";
      template_name = "pmm_mysql_down";
      name = "MySQL Instance Down";
      group = "template";
      params = [ ];
      for = "60s";
      severity = "SEVERITY_CRITICAL";
      custom_labels = {
        source = "pxc-pmm";
        route = "pagerduty";
        managed_by = "pxc-pmm-alerts-controller";
      };
      filters = [ ];
    }
    {
      name = "No MySQL Instances Monitored";
      group = "expression";
      expr = "absent(mysql_global_status_uptime)";
      for = "120s";
      no_data_state = "OK";
      custom_labels = {
        source = "pxc-pmm";
        severity = "critical";
        route = "pagerduty";
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Disk Usage Warning";
      group = "expression";
      expr = "(1 - (node_filesystem_avail_bytes{mountpoint=~\"/var/lib/mysql|/data\"} / node_filesystem_size_bytes{mountpoint=~\"/var/lib/mysql|/data\"})) * 100 > 75";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = "default";
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC Disk Usage Critical";
      group = "expression";
      expr = "(1 - (node_filesystem_avail_bytes{mountpoint=~\"/var/lib/mysql|/data\"} / node_filesystem_size_bytes{mountpoint=~\"/var/lib/mysql|/data\"})) * 100 > 90";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = "pagerduty";
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
        route = "default";
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "PXC mysql_up Critical";
      group = "expression";
      expr = "sum by (service_name)(mysql_up == 0) > 0";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = "pagerduty";
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
        route = "default";
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
        route = "pagerduty";
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "Galera Flow Control Warning";
      group = "expression";
      expr = "avg by (service_name)(mysql_global_status_wsrep_flow_control_paused_ns / 1e9) > 0.1";
      for = "10m";
      no_data_state = "OK";
      custom_labels = {
        severity = "warning";
        route = "default";
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
    {
      name = "Galera Flow Control Critical";
      group = "expression";
      expr = "avg by (service_name)(mysql_global_status_wsrep_flow_control_paused_ns / 1e9) > 0.3";
      for = "5m";
      no_data_state = "OK";
      custom_labels = {
        severity = "critical";
        route = "pagerduty";
        managed_by = "pxc-pmm-alerts-controller";
      };
      folder_uid = "__MYSQL_FOLDER_UID__";
    }
  ];

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
    items = objects;
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

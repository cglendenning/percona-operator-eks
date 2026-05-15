{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.projects.grafanaSeaweed;
  yaml = pkgs.formats.yaml { };

  alertRules = import ./alerts.nix { };

  exprRules = filter (r: r ? expr) alertRules;

  ignoredTemplates = filter (r: (r ? template_name) && !(r ? expr)) alertRules;

  rulesForHash =
    if ignoredTemplates == [ ] then
      exprRules
    else
      trace (
        "projects.grafanaSeaweed: ignoring ${toString (length ignoredTemplates)} "
        + "template-only rule(s) (no expr); they are not provisioned to Grafana."
      ) exprRules;

  rulesHash = builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON rulesForHash));

  # Grafana rule UIDs: max 40 chars; only [A-Za-z0-9_-]
  stableRuleUid = rule:
    let
      h = builtins.hashString "sha256" (rule.name + ":" + rule.expr);
    in
    "sw-" + builtins.substring 0 32 h;

  # Mirrors the Grafana ruler payload used in `../pmm/default.nix` for custom `expr` rules
  # (Prometheus query A + classic_conditions on B), serialized for file provisioning.
  grafanaFileRule = rule:
    let
      forDur = rule.for or "60s";
      noData = rule.no_data_state or "OK";
      ruleLabels = rule.custom_labels or { };
    in
    {
      uid = stableRuleUid rule;
      title = rule.name;
      condition = "B";
      data = [
        {
          refId = "A";
          queryType = "";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          datasourceUid = cfg.prometheusDatasourceUid;
          model = {
            datasource = {
              type = "prometheus";
              uid = cfg.prometheusDatasourceUid;
            };
            expr = rule.expr;
            refId = "A";
            legendFormat = "";
            instant = false;
            range = true;
            intervalMs = 1000;
            maxDataPoints = 43200;
          };
        }
        {
          refId = "B";
          queryType = "";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            type = "classic_conditions";
            refId = "B";
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
            conditions = [
              {
                evaluator = {
                  params = [ 0 ];
                  type = "gt";
                };
                operator = {
                  type = "and";
                };
                query = {
                  params = [ "A" ];
                };
                reducer = {
                  params = [ ];
                  type = "last";
                };
              }
            ];
          };
        }
      ];
      noDataState = noData;
      execErrState = "Alerting";
      "for" = forDur;
      labels = ruleLabels;
      annotations = { };
      isPaused = false;
    };

  alertingRulesDocument = {
    apiVersion = 1;
    groups = [
      {
        orgId = 1;
        name = cfg.ruleGroupName;
        folder = cfg.alertFolderTitle;
        interval = "${toString cfg.evalIntervalSeconds}s";
        rules = map grafanaFileRule exprRules;
      }
    ];
  };

  datasourceDocument = {
    apiVersion = 1;
    datasources = [
      {
        name = cfg.prometheusDatasourceName;
        type = "prometheus";
        access = "proxy";
        uid = cfg.prometheusDatasourceUid;
        orgId = 1;
        url = cfg.prometheusUrl;
        isDefault = cfg.prometheusDatasourceIsDefault;
        editable = false;
      }
    ];
  };

  rulesYaml = yaml.generate "seaweed-alert-rules.yaml" alertingRulesDocument;

  datasourceYamlFile = yaml.generate "seaweed-datasources.yaml" datasourceDocument;

  configMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = cfg.configMapName;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/name" = "grafana-seaweed-alert-provisioning";
      };
      annotations = {
        "grafana.wookie/rules-hash" = rulesHash;
      };
    };
    data = {
      "seaweed-alert-rules.yaml" = builtins.readFile rulesYaml;
    }
    // optionalAttrs cfg.provisionPrometheusDatasource {
      "seaweed-datasources.yaml" = builtins.readFile datasourceYamlFile;
    };
  };

  manifestDrvs =
    if exprRules == [ ] then
      throw "projects.grafanaSeaweed: enable is true but alerts.nix defines no rules with `expr`."
    else
      pkgs.runCommand "grafana-seaweed-alert-manifests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
        set -euo pipefail
        grep -q "SeaweedFS_volumeServer_resource" "${rulesYaml}" || {
          echo "rules YAML missing expected metric" >&2
          exit 1
        }
        grep -q "${cfg.alertFolderTitle}" "${rulesYaml}" || {
          echo "rules YAML missing folder title" >&2
          exit 1
        }
        mkdir -p "$out"
        {
          echo "---"
          cat ${yaml.generate "configmap.yaml" configMap}
        } > "$out/manifest.yaml"
      '';

in
{
  options.projects.grafanaSeaweed = {
    enable = mkEnableOption "static Grafana SeaweedFS alert rule ConfigMap (file-provisioning YAML)";

    namespace = mkOption {
      type = types.str;
      default = "monitoring";
      description = "Kubernetes namespace for the ConfigMap.";
    };

    configMapName = mkOption {
      type = types.str;
      default = "grafana-seaweed-alert-provisioning";
      description = "ConfigMap name mounted into Grafana provisioning.";
    };

    bundleName = mkOption {
      type = types.str;
      default = "grafana-seaweed-alerts";
      description = "Kubernetes batch bundle name (Fleet / kubelib).";
    };

    dependsOn = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Other bundle names that must sync first (for example your Grafana Helm release).
        Fleet applies `dependsOn` ordering between bundles.
      '';
    };

    alertFolderTitle = mkOption {
      type = types.str;
      default = "seaweed-alerts";
      description = ''
        Grafana alert folder title written to provisioning YAML (`folder:` field).
        No folder UID lookup is required for file provisioning.
      '';
    };

    ruleGroupName = mkOption {
      type = types.str;
      default = "seaweed-alerts";
      description = "Grafana rule group `name` inside the provisioned YAML.";
    };

    evalIntervalSeconds = mkOption {
      type = types.ints.positive;
      default = 60;
      description = "Evaluation interval for the provisioned rule group.";
    };

    prometheusDatasourceUid = mkOption {
      type = types.str;
      default = "prometheus";
      description = ''
        UID of the Prometheus datasource Grafana uses for these rules.
        Must match an existing datasource or the UID in optional datasource provisioning below.
      '';
    };

    provisionPrometheusDatasource = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, emit an additional `seaweed-datasources.yaml` key for file provisioning.
        Leave false if Grafana already has a Prometheus datasource with
        `prometheusDatasourceUid`.
      '';
    };

    prometheusDatasourceName = mkOption {
      type = types.str;
      default = "Prometheus (Seaweed)";
      description = "Display name when `provisionPrometheusDatasource` is true.";
    };

    prometheusUrl = mkOption {
      type = types.str;
      default = "http://prometheus-k8s.monitoring.svc:9090";
      description = "Prometheus HTTP URL when `provisionPrometheusDatasource` is true.";
    };

    prometheusDatasourceIsDefault = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the provisioned Prometheus datasource should be the default.";
    };
  };

  config = mkIf cfg.enable {
    platform.kubernetes.cluster.batches.services.bundles.${cfg.bundleName} = {
      namespace = cfg.namespace;
      dependsOn = cfg.dependsOn;
      manifests = [ manifestDrvs ];
    };
  };
}

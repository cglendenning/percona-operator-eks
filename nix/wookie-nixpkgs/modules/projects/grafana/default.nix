{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.projects.grafana;

  grafanaAlerting = import ../../../lib/grafana-alerting.nix { inherit lib; };

  seaweedSpecs = import ./alerts/seaweed.nix { };

  seaweedRules =
    map (
      spec:
      grafanaAlerting.promqlBooleanRule {
        inherit (spec) title expr for noDataState labels;
        datasourceUid = cfg.prometheusDatasourceUid;
      }
    ) seaweedSpecs;

  seaweedAlertingDocument = {
    apiVersion = 1;
    groups = [
      {
        orgId = 1;
        name = cfg.seaweedRuleGroupName;
        folder = cfg.seaweedAlertFolder;
        interval = "${toString cfg.evalIntervalSeconds}s";
        rules = seaweedRules;
      }
    ];
  };

  grafanaChartPkg = pkgs.fetchurl {
    url = "https://github.com/grafana/helm-charts/releases/download/grafana-${cfg.chartVersion}/grafana-${cfg.chartVersion}.tgz";
    sha256 = cfg.chartHash;
  };

in
{
  options.projects.grafana = {
    enable = mkEnableOption "Grafana server (Helm) with file-provisioned alerting";

    namespace = mkOption {
      type = types.str;
      default = "monitoring";
    };

    chartVersion = mkOption {
      type = types.str;
      default = "8.8.2";
    };

    chartHash = mkOption {
      type = types.str;
      default = "sha256-skSgTM+slQhTCA7t5r8bcWspZspwfmn282I7PWkONrg=";
      description = ''
        Run: nix-prefetch-url https://github.com/grafana/helm-charts/releases/download/grafana-<version>/grafana-<version>.tgz
      '';
    };

    adminPassword = mkOption {
      type = types.str;
      default = "admin";
    };

    prometheusDatasourceUid = mkOption {
      type = types.str;
      default = "prometheus";
      description = "UID of the Prometheus datasource used by provisioned alert rules.";
    };

    seaweedAlertFolder = mkOption {
      type = types.str;
      default = "seaweed-alerts";
    };

    seaweedRuleGroupName = mkOption {
      type = types.str;
      default = "seaweed-alerts";
    };

    evalIntervalSeconds = mkOption {
      type = types.ints.positive;
      default = 60;
    };

    persistence = mkOption {
      type = types.bool;
      default = true;
    };

    storageClass = mkOption {
      type = types.str;
      default = "standard";
    };

    storageSize = mkOption {
      type = types.str;
      default = "10Gi";
    };
  };

  config = mkIf cfg.enable {
    platform.kubernetes.cluster.batches.services.bundles.grafana = {
      namespace = cfg.namespace;
      chart = {
        name = "grafana";
        version = builtins.replaceStrings [ "." ] [ "_" ] cfg.chartVersion;
        package = grafanaChartPkg;
        values = {
          persistence = {
            enabled = cfg.persistence;
            storageClassName = cfg.storageClass;
            size = cfg.storageSize;
          };
          adminPassword = cfg.adminPassword;
          alerting."seaweed.yaml" = seaweedAlertingDocument;
        };
      };
    };
  };
}

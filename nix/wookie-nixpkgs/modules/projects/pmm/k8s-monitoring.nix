# Victoria Metrics k8s stack + Percona kube-state-metrics CR config → remote-write to PMM.
# https://docs.percona.com/percona-operator-for-mysql/pxc/monitor-kubernetes.html
{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.projects.pmm;
  kmCfg = cfg.k8sMonitoring;

  ksm = import ./ksm-configmap.nix { inherit lib pkgs; };
  yaml = pkgs.formats.yaml {};

  pmmWriteUrl =
    "https://${cfg.serviceName}.${cfg.namespace}.svc.cluster.local/victoriametrics/api/v1/write";

  chartValues = import ./k8s-monitoring-values.nix {
    inherit pmmWriteUrl;
    k8sClusterId = kmCfg.k8sClusterId;
    nodeExporterEnabled = kmCfg.nodeExporterEnabled;
    tokenSecretName = kmCfg.tokenSecretName;
    tokenSecretKey = kmCfg.tokenSecretKey;
  };

  prereqManifests = pkgs.runCommand "pmm-k8s-monitoring-prereqs" { } ''
    mkdir -p $out
    cp ${yaml.generate "manifest.yaml" (ksm.mkKsmConfigMap kmCfg.namespace)} $out/manifest.yaml
  '';

  vmK8sStackChart = pkgs.fetchurl {
    url = "https://github.com/VictoriaMetrics/helm-charts/releases/download/victoria-metrics-k8s-stack-${kmCfg.chartVersion}/victoria-metrics-k8s-stack-${kmCfg.chartVersion}.tgz";
    sha256 = kmCfg.chartHash;
  };

in
{
  options.projects.pmm.k8sMonitoring = {
    enable = mkEnableOption ''
      Victoria Metrics Kubernetes monitoring stack (vmagent + kube-state-metrics with
      Percona operator CR metrics) remote-writing to the in-cluster PMM server.
    '';

    namespace = mkOption {
      type = types.str;
      default = "wookie-observability";
      description = ''
        Namespace for vm-k8s-stack, KSM ConfigMap, and the existing PMM token Secret
        (pmm-service-account-token / pmmservertoken). Must match where observability
        already stores the token.
      '';
    };

    chartVersion = mkOption {
      type = types.str;
      default = "0.30.3";
      description = "victoria-metrics-k8s-stack chart version (Percona k8s-monitoring v0.1.1 pin).";
    };

    chartHash = mkOption {
      type = types.str;
      default = "sha256-Q1QIg8PoVyU+VzlTCO8+ZpdHX7J4e6RQFIkuDv7JLUk=";
      description = ''
        Run: nix-prefetch-url https://github.com/VictoriaMetrics/helm-charts/releases/download/victoria-metrics-k8s-stack-<version>/victoria-metrics-k8s-stack-<version>.tgz
      '';
    };

    tokenSecretName = mkOption {
      type = types.str;
      default = "pmm-service-account-token";
      description = "Existing Secret in namespace (not created by this module).";
    };

    tokenSecretKey = mkOption {
      type = types.str;
      default = "pmmservertoken";
      description = "Secret data key holding the PMM glsa_… token.";
    };

    k8sClusterId = mkOption {
      type = types.str;
      description = ''
        Unique cluster label (vmagent externalLabels.k8s_cluster_id). Use a distinct value
        per Kubernetes cluster when multiple clusters remote-write to one PMM server.
      '';
    };

    nodeExporterEnabled = mkOption {
      type = types.bool;
      default = false;
      description = "Enable prometheus-node-exporter (requires privileged host access).";
    };
  };

  config = mkIf (cfg.enable && kmCfg.enable) {
    platform.kubernetes.cluster.batches.services.bundles.pmm-k8s-monitoring-prereqs = {
      namespace = kmCfg.namespace;
      dependsOn = [ "pmm-server" ];
      manifests = [ prereqManifests ];
    };

    platform.kubernetes.cluster.batches.services.bundles.pmm-k8s-monitoring = {
      namespace = kmCfg.namespace;
      dependsOn = [ "pmm-k8s-monitoring-prereqs" ];
      chart = {
        name = "victoria-metrics-k8s-stack";
        version = builtins.replaceStrings [ "." ] [ "_" ] kmCfg.chartVersion;
        package = vmK8sStackChart;
        values = chartValues;
      };
    };
  };
}

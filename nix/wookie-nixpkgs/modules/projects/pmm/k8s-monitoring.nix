# Victoria Metrics k8s stack + Percona kube-state-metrics CR config → remote-write to PMM.
# https://docs.percona.com/percona-operator-for-mysql/pxc/monitor-kubernetes.html
{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.projects.pmm;
  kmCfg = cfg.k8sMonitoring;
  yaml = pkgs.formats.yaml { };

  perconaKsmConfigMap = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/Percona-Lab/k8s-monitoring/refs/tags/v0.1.1/vm-operator-k8s-stack/ksm-configmap.yaml";
    sha256 = "sha256-aNVbYIZ9YyV1n8A6hT0OTj/C9QjtFhu9e2NNDFRhoW8=";
  };

  pmmWriteUrl =
    "https://${cfg.serviceName}.${cfg.namespace}.svc.cluster.local/victoriametrics/api/v1/write";

  chartValues = import ./k8s-monitoring-values.nix {
    inherit pmmWriteUrl;
    k8sClusterId = kmCfg.k8sClusterId;
    nodeExporterEnabled = kmCfg.nodeExporterEnabled;
    tokenSecretName = kmCfg.tokenSecretName;
    tokenSecretKey = kmCfg.tokenSecretKey;
  };

  # vmagent mounts secrets in the release namespace; copy pmmservertoken from wookie-observability.
  tokenSyncJob = {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata = {
      name = "pmm-k8s-monitoring-token-sync";
      namespace = kmCfg.namespace;
      labels = { "app.kubernetes.io/name" = "pmm-k8s-monitoring-token-sync"; };
    };
    spec = {
      # Retries happen inside the container; avoid extra Failed pods from Job-level backoff.
      backoffLimit = 0;
      completions = 1;
      parallelism = 1;
      # Remove Job + pods shortly after success or failure so kubectl stays clean.
      ttlSecondsAfterFinished = 120;
      activeDeadlineSeconds = 660;
      template = {
        metadata.labels."app.kubernetes.io/name" = "pmm-k8s-monitoring-token-sync";
        spec = {
          serviceAccountName = "pmm-k8s-monitoring-token-sync";
          restartPolicy = "Never";
          containers = [{
            name = "sync";
            image = "bitnami/kubectl:1.31";
            imagePullPolicy = "IfNotPresent";
            env = [
              { name = "SOURCE_NS"; value = kmCfg.tokenSecretNamespace; }
              { name = "SOURCE_SECRET"; value = kmCfg.tokenSecretName; }
              { name = "SOURCE_KEY"; value = kmCfg.tokenSecretKey; }
              { name = "TARGET_NS"; value = kmCfg.namespace; }
              { name = "TARGET_SECRET"; value = kmCfg.tokenSecretName; }
              { name = "TARGET_KEY"; value = kmCfg.tokenSecretKey; }
              { name = "READ_MAX_ATTEMPTS"; value = "36"; }
              { name = "READ_SLEEP_SEC"; value = "10"; }
              { name = "APPLY_MAX_ATTEMPTS"; value = "6"; }
              { name = "APPLY_SLEEP_SEC"; value = "5"; }
            ];
            command = [ "bash" "-ec" ];
            args = [ ''
              set -euo pipefail

              read_token() {
                kubectl get secret "$SOURCE_SECRET" -n "$SOURCE_NS" \
                  -o "jsonpath={.data.$SOURCE_KEY}" 2>/dev/null | base64 -d || true
              }

              retry() {
                local label="$1" max="$2" sleep_sec="$3"
                shift 3
                local attempt=1
                while [ "$attempt" -le "$max" ]; do
                  echo "[token-sync] $label (attempt $attempt/$max)..."
                  if "$@"; then
                    return 0
                  fi
                  if [ "$attempt" -eq "$max" ]; then
                    echo "[token-sync] $label failed after $max attempts" >&2
                    return 1
                  fi
                  sleep "$sleep_sec"
                  attempt=$((attempt + 1))
                done
              }

              wait_for_token() {
                local token
                token="$(read_token)"
                [ -n "$token" ]
              }

              apply_target_secret() {
                local token="$1"
                kubectl create secret generic "$TARGET_SECRET" -n "$TARGET_NS" \
                  --from-literal="$TARGET_KEY=$token" \
                  --dry-run=client -o yaml | kubectl apply -f -
              }

              echo "[token-sync] source ${kmCfg.tokenSecretNamespace}/${kmCfg.tokenSecretName} (${kmCfg.tokenSecretKey})"
              echo "[token-sync] target $TARGET_NS/$TARGET_SECRET ($TARGET_KEY)"

              token=""
              retry "waiting for source secret" "$READ_MAX_ATTEMPTS" "$READ_SLEEP_SEC" wait_for_token
              token="$(read_token)"
              if [ -z "$token" ]; then
                echo "[token-sync] ERROR: empty token after wait" >&2
                exit 1
              fi

              retry "upserting target secret" "$APPLY_MAX_ATTEMPTS" "$APPLY_SLEEP_SEC" \
                apply_target_secret "$token"

              echo "[token-sync] done."
            '' ];
          }];
        };
      };
    };
  };

  tokenSyncRbac = [
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = "pmm-k8s-monitoring-token-sync";
        namespace = kmCfg.namespace;
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "pmm-k8s-monitoring-token-sync";
        namespace = kmCfg.namespace;
      };
      rules = [{
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [ "get" "create" "patch" "update" ];
      }];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "pmm-k8s-monitoring-token-read";
        namespace = kmCfg.tokenSecretNamespace;
      };
      rules = [{
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        resourceNames = [ kmCfg.tokenSecretName ];
        verbs = [ "get" ];
      }];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "pmm-k8s-monitoring-token-sync";
        namespace = kmCfg.namespace;
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "pmm-k8s-monitoring-token-sync";
        namespace = kmCfg.namespace;
      }];
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "pmm-k8s-monitoring-token-sync";
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "pmm-k8s-monitoring-token-sync-read";
        namespace = kmCfg.tokenSecretNamespace;
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "pmm-k8s-monitoring-token-sync";
        namespace = kmCfg.namespace;
      }];
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "pmm-k8s-monitoring-token-read";
      };
    }
  ];

  rbacYamlFiles = lib.imap0 (
    i: obj:
    yaml.generate "token-sync-rbac-${toString i}.yaml" obj
  ) tokenSyncRbac;

  prereqManifests = pkgs.runCommand "pmm-k8s-monitoring-prereqs" { } ''
    mkdir -p $out
    {
      ${lib.concatMapStringsSep "\n      echo \"---\"\n      cat " (f: "${f}") rbacYamlFiles}
      echo "---"
      cat ${yaml.generate "token-sync-job.yaml" tokenSyncJob}
      echo "---"
      sed 's|#namespace: default|namespace: ${kmCfg.namespace}|' ${perconaKsmConfigMap}
    } > $out/manifest.yaml
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
      default = "monitoring-system";
      description = "Namespace for vm-k8s-stack and KSM prerequisites.";
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

    tokenSecretNamespace = mkOption {
      type = types.str;
      default = "wookie-observability";
      description = ''
        Namespace of the PMM service account token Secret (source of truth for remote-write).
      '';
    };

    tokenSecretName = mkOption {
      type = types.str;
      default = "pmm-service-account-token";
      description = "Secret name for the PMM service account token (source and vmagent mount).";
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

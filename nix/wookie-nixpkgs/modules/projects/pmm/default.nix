{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.projects.pmm;
  yaml = pkgs.formats.yaml {};
  alertRules = import ./alerts.nix {};

  # Changes when alerts.nix changes → annotation on the Job changes →
  # Helm hook re-executes on next helmfile sync
  rulesHash = builtins.substring 0 12 (
    builtins.hashString "sha256" (builtins.toJSON alertRules)
  );

  configMapData = builtins.listToAttrs (
    lib.imap1 (i: rule: {
      name  = "${builtins.toString i}-${builtins.replaceStrings [" "] ["-"] rule.name}.json";
      value = builtins.toJSON rule;
    }) alertRules
  );

  configMap = {
    apiVersion = "v1";
    kind       = "ConfigMap";
    metadata   = { name = "pmm-alert-rules"; namespace = cfg.namespace; };
    data       = configMapData;
  };

  # Post-install/upgrade Job. Helm deletes the previous Job before creating
  # a new one (before-hook-creation) and deletes it on success (hook-succeeded).
  # The rulesHash annotation ensures the spec changes when alerts.nix changes,
  # causing Helm to re-execute the hook on the next upgrade.
  provisionerJob = {
    apiVersion = "batch/v1";
    kind       = "Job";
    metadata   = {
      name      = "pmm-alert-provisioner";
      namespace = cfg.namespace;
      annotations = {
        "helm.sh/hook"               = "post-install,post-upgrade";
        "helm.sh/hook-delete-policy" = "before-hook-creation,hook-succeeded";
        "helm.sh/hook-weight"        = "5";
        "pmm.wookie/rules-hash"      = rulesHash;
      };
    };
    spec = {
      backoffLimit = 5;
      template = {
        metadata.labels."app.kubernetes.io/name" = "pmm-alert-provisioner";
        spec = {
          restartPolicy = "OnFailure";
          containers = [{
            name    = "provisioner";
            image   = "curlimages/curl:8.11.0";
            env     = [{ name = "PMM_ADMIN_PASSWORD"; value = cfg.adminPassword; }];
            command = [ "/bin/sh" "-c" ''
              set -eu
              RULES_DIR=/etc/pmm-alerts
              PMM_URL=https://${cfg.serviceName}.${cfg.namespace}.svc.cluster.local

              echo "=== pmm-alert-provisioner: waiting for PMM ==="
              i=0
              while [ $i -lt 60 ]; do
                if curl -sfk -u "admin:$PMM_ADMIN_PASSWORD" "$PMM_URL/v1/readyz" >/dev/null 2>&1; then
                  echo "PMM ready"
                  break
                fi
                sleep 5
                i=$((i + 1))
              done

              echo "Provisioning rules from $RULES_DIR ..."
              for f in "$RULES_DIR"/*.json; do
                [ -f "$f" ] || { echo "No rule files found"; break; }
                rule_name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
                echo "Processing: $rule_name"

                if curl -sfk -u "admin:$PMM_ADMIN_PASSWORD" \
                    "$PMM_URL/v1/alerting/rules" 2>/dev/null \
                    | grep -qF "\"$rule_name\""; then
                  echo "  already exists - skipping"
                  continue
                fi

                result=$(curl -sk -o /tmp/resp.txt -w "%{http_code}" \
                  -X POST \
                  -u "admin:$PMM_ADMIN_PASSWORD" \
                  -H "Content-Type: application/json" \
                  -d "@$f" \
                  "$PMM_URL/v1/alerting/rules")

                if [ "$result" = "200" ] || [ "$result" = "201" ]; then
                  echo "  created (HTTP $result)"
                else
                  echo "  ERROR: HTTP $result: $(cat /tmp/resp.txt)"
                  exit 1
                fi
              done
              echo "=== pmm-alert-provisioner: done ==="
            ''];
            volumeMounts = [{
              name      = "pmm-alert-rules";
              mountPath = "/etc/pmm-alerts";
              readOnly  = true;
            }];
          }];
          volumes = [{
            name      = "pmm-alert-rules";
            configMap.name = "pmm-alert-rules";
          }];
        };
      };
    };
  };

  pmmChartPkg = pkgs.fetchurl {
    url    = "https://percona.github.io/percona-helm-charts/pmm-${cfg.chartVersion}.tgz";
    sha256 = cfg.chartHash;
  };

in
{
  options.projects.pmm = {
    enable = mkEnableOption "PMM server with alert provisioner";

    namespace = mkOption {
      type    = types.str;
      default = "pmm";
    };

    adminPassword = mkOption {
      type    = types.str;
      default = "admin";
    };

    chartVersion = mkOption {
      type    = types.str;
      default = "3.0.0";
    };

    # Run: nix-prefetch-url https://percona.github.io/percona-helm-charts/pmm-<version>.tgz
    chartHash = mkOption {
      type = types.str;
    };

    # Kubernetes service name created by the Helm chart (defaults to release name)
    serviceName = mkOption {
      type    = types.str;
      default = "pmm";
    };

    storageClass = mkOption {
      type    = types.str;
      default = "standard";
    };

    storageSize = mkOption {
      type    = types.str;
      default = "20Gi";
    };

    resources = mkOption {
      type    = types.attrs;
      default = {
        requests = { memory = "1Gi"; cpu = "500m"; };
        limits   = { memory = "2Gi"; cpu = "1"; };
      };
    };
  };

  config = mkIf cfg.enable {
    # PMM server deployed via the official Percona Helm chart
    platform.kubernetes.cluster.batches.services.bundles.pmm-server = {
      namespace = cfg.namespace;
      chart = {
        name    = "pmm";
        version = builtins.replaceStrings ["."] ["_"] cfg.chartVersion;
        package = pmmChartPkg;
        values  = {
          pmm.server = {
            resources   = cfg.resources;
            persistence = {
              enabled      = true;
              storageClass = cfg.storageClass;
              size         = cfg.storageSize;
            };
          };
          service  = { type = "ClusterIP"; port = 443; };
          ingress.enabled = false;
        };
      };
    };

    # ConfigMap + provisioner Job - runs after PMM is deployed
    platform.kubernetes.cluster.batches.services.bundles.pmm-alerts = {
      namespace  = cfg.namespace;
      dependsOn  = [ "pmm-server" ];
      manifests  = [(
        pkgs.runCommand "pmm-alert-manifests" {} ''
          mkdir -p $out
          {
            echo "---"
            cat ${yaml.generate "configmap.yaml" configMap}
            echo "---"
            cat ${yaml.generate "job.yaml" provisionerJob}
          } > $out/manifest.yaml
        ''
      )];
    };
  };
}

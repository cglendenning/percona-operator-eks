{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.projects.pmm;
  yaml = pkgs.formats.yaml {};
  pmmHelpers = import ../../pkgs/pmm.nix { inherit lib; };
  alertRules = import ./alerts.nix {};

  # Builds the alert-provisioner sidecar container, its volume, and the
  # ConfigMap that holds each rule as a JSON file.  The sidecar waits for
  # PMM to be ready, then idempotently POSTs any rule that doesn't yet exist.
  mkAlertProvisioner = { namespace, adminPassword, rules }:
    let
      configMapData = builtins.listToAttrs (
        lib.imap1 (i: rule: {
          name  = "${builtins.toString i}-${builtins.replaceStrings [" "] ["-"] rule.name}.json";
          value = builtins.toJSON rule;
        }) rules
      );
    in {
      configMap = {
        apiVersion = "v1";
        kind       = "ConfigMap";
        metadata   = {
          name      = "pmm-alert-rules";
          inherit namespace;
        };
        data = configMapData;
      };

      volume = {
        name      = "pmm-alert-rules";
        configMap.name = "pmm-alert-rules";
      };

      container = {
        name  = "alert-provisioner";
        image = "curlimages/curl:8.11.0";
        env   = [{ name = "PMM_ADMIN_PASSWORD"; value = adminPassword; }];
        command = [ "/bin/sh" "-c" ''
          set -eu
          RULES_DIR=/etc/pmm-alerts
          PMM_URL=http://localhost

          echo "=== alert-provisioner: waiting for PMM ==="
          i=0
          while [ $i -lt 60 ]; do
            if curl -sf -u "admin:$PMM_ADMIN_PASSWORD" "$PMM_URL/v1/readyz" >/dev/null 2>&1; then
              echo "PMM ready"
              break
            fi
            sleep 5
            i=$((i + 1))
          done

          echo "Provisioning alert rules from $RULES_DIR ..."
          for f in "$RULES_DIR"/*.json; do
            [ -f "$f" ] || { echo "No rule files found in $RULES_DIR"; break; }
            rule_name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
            echo "Processing: $rule_name"

            if curl -sf -u "admin:$PMM_ADMIN_PASSWORD" \
                "$PMM_URL/v1/alerting/rules" 2>/dev/null \
                | grep -qF "\"$rule_name\""; then
              echo "  already exists - skipping"
              continue
            fi

            result=$(curl -s -o /tmp/alert_resp.txt -w "%{http_code}" \
              -X POST \
              -u "admin:$PMM_ADMIN_PASSWORD" \
              -H "Content-Type: application/json" \
              -d "@$f" \
              "$PMM_URL/v1/alerting/rules")

            if [ "$result" = "200" ] || [ "$result" = "201" ]; then
              echo "  created (HTTP $result)"
            else
              echo "  WARNING: HTTP $result: $(cat /tmp/alert_resp.txt)"
            fi
          done

          echo "=== alert-provisioner: done. Sleeping. ==="
          exec sleep infinity
        ''];
        volumeMounts = [{
          name      = "pmm-alert-rules";
          mountPath = "/etc/pmm-alerts";
          readOnly  = true;
        }];
      };
    };

in
{
  options.projects.pmm = {
    enable = mkEnableOption "PMM project with Vault and External Secrets";

    pmm = {
      enable = mkEnableOption "PMM v3 server";
      
      version = mkOption {
        type = types.str;
        default = "3.0.0";
        description = "PMM server version";
      };
      
      namespace = mkOption {
        type = types.str;
        default = "pmm";
        description = "Namespace for PMM";
      };
      
      adminPassword = mkOption {
        type = types.str;
        default = "admin";
        description = "PMM admin password";
      };
    };
    
    vault = {
      enable = mkEnableOption "HashiCorp Vault";
      
      namespace = mkOption {
        type = types.str;
        default = "vault";
        description = "Namespace for Vault";
      };
      
      devMode = mkOption {
        type = types.bool;
        default = true;
        description = "Run Vault in dev mode";
      };
      
      rootToken = mkOption {
        type = types.str;
        default = "root";
        description = "Vault root token (dev mode)";
      };
    };
    
    externalSecrets = {
      enable = mkEnableOption "External Secrets Operator";
      
      namespace = mkOption {
        type = types.str;
        default = "external-secrets";
        description = "Namespace for External Secrets Operator";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Namespaces
    {
      platform.kubernetes.cluster.batches.namespaces.bundles = mkMerge [
        (mkIf cfg.pmm.enable {
          pmm-namespace = {
            namespace = cfg.pmm.namespace;
            manifests = [(
              let
                ns = {
                  apiVersion = "v1";
                  kind = "Namespace";
                  metadata.name = cfg.pmm.namespace;
                };
              in
              pkgs.runCommand "pmm-namespace" {} ''
                mkdir -p $out
                cat ${yaml.generate "manifest.yaml" ns} > $out/manifest.yaml
              ''
            )];
          };
        })
        
        (mkIf cfg.vault.enable {
          vault-namespace = {
            namespace = cfg.vault.namespace;
            manifests = [(
              let
                ns = {
                  apiVersion = "v1";
                  kind = "Namespace";
                  metadata.name = cfg.vault.namespace;
                };
              in
              pkgs.runCommand "vault-namespace" {} ''
                mkdir -p $out
                cat ${yaml.generate "manifest.yaml" ns} > $out/manifest.yaml
              ''
            )];
          };
        })
        
        (mkIf cfg.externalSecrets.enable {
          external-secrets-namespace = {
            namespace = cfg.externalSecrets.namespace;
            manifests = [(
              let
                ns = {
                  apiVersion = "v1";
                  kind = "Namespace";
                  metadata.name = cfg.externalSecrets.namespace;
                };
              in
              pkgs.runCommand "external-secrets-namespace" {} ''
                mkdir -p $out
                cat ${yaml.generate "manifest.yaml" ns} > $out/manifest.yaml
              ''
            )];
          };
        })
      ];
    }
    
    # PMM Server
    (mkIf cfg.pmm.enable {
      platform.kubernetes.cluster.batches.services.bundles.pmm-server = {
        namespace = cfg.pmm.namespace;
        manifests = [(
          let
            sidecar = pmmHelpers.mkPMMServiceAccountSidecar {
              saName = "wookie-pmm-sa";
              saRole = "Admin";
              tokenName = "wookie-pmm-token";
              adminUser = "admin";
              adminPassword = cfg.pmm.adminPassword;
            };

            alertProvisioner = mkAlertProvisioner {
              namespace     = cfg.pmm.namespace;
              adminPassword = cfg.pmm.adminPassword;
              rules         = alertRules;
            };

            deployment = {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = {
                name = "pmm-server";
                namespace = cfg.pmm.namespace;
              };
              spec = {
                replicas = 1;
                selector.matchLabels.app = "pmm-server";
                template = {
                  metadata.labels.app = "pmm-server";
                  spec = {
                    containers = [
                      {
                        name = "pmm-server";
                        image = "percona/pmm-server:${cfg.pmm.version}";
                        ports = [
                          { containerPort = 80; name = "http"; }
                          { containerPort = 443; name = "https"; }
                        ];
                        env = [
                          { name = "DISABLE_UPDATES"; value = "true"; }
                          { name = "PMM_DEBUG"; value = "1"; }
                        ];
                        livenessProbe = {
                          httpGet = { path = "/v1/readyz"; port = 80; };
                          initialDelaySeconds = 60;
                          periodSeconds = 10;
                          timeoutSeconds = 5;
                        };
                        readinessProbe = {
                          httpGet = { path = "/v1/readyz"; port = 80; };
                          initialDelaySeconds = 30;
                          periodSeconds = 5;
                          timeoutSeconds = 3;
                        };
                      }
                      sidecar.container
                      alertProvisioner.container
                    ];
                    volumes = [
                      sidecar.volume
                      alertProvisioner.volume
                    ];
                  };
                };
              };
            };

            service = {
              apiVersion = "v1";
              kind = "Service";
              metadata = {
                name = "pmm-server";
                namespace = cfg.pmm.namespace;
              };
              spec = {
                type = "LoadBalancer";
                selector.app = "pmm-server";
                ports = [
                  { name = "http"; port = 80; targetPort = 80; protocol = "TCP"; }
                  { name = "https"; port = 443; targetPort = 443; protocol = "TCP"; }
                ];
              };
            };

            allManifests = [ alertProvisioner.configMap deployment service ];
          in
          pkgs.runCommand "pmm-server-manifests" {} ''
            mkdir -p $out
            ${lib.concatMapStringsSep "\n" (manifest: ''
              echo "---" >> $out/manifest.yaml
              cat ${yaml.generate "manifest.yaml" manifest} >> $out/manifest.yaml
            '') allManifests}
          ''
        )];
      };
    })
    
    # Vault
    (mkIf cfg.vault.enable {
      platform.kubernetes.cluster.batches.services.bundles.vault = {
        namespace = cfg.vault.namespace;
        manifests = [(
          let
            deployment = {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = {
                name = "vault";
                namespace = cfg.vault.namespace;
                labels."app.kubernetes.io/name" = "vault";
              };
              spec = {
                replicas = 1;
                selector.matchLabels."app.kubernetes.io/name" = "vault";
                template = {
                  metadata.labels."app.kubernetes.io/name" = "vault";
                  spec = {
                    containers = [{
                      name = "vault";
                      image = "hashicorp/vault:1.15";
                      ports = [
                        { containerPort = 8200; name = "http"; }
                        { containerPort = 8201; name = "https-internal"; }
                      ];
                      env = [
                        { name = "VAULT_DEV_ROOT_TOKEN_ID"; value = cfg.vault.rootToken; }
                        { name = "VAULT_DEV_LISTEN_ADDRESS"; value = "0.0.0.0:8200"; }
                        { name = "VAULT_ADDR"; value = "http://127.0.0.1:8200"; }
                      ];
                      args = [ "server" "-dev" ];
                      securityContext.capabilities.add = [ "IPC_LOCK" ];
                      readinessProbe = {
                        httpGet = {
                          path = "/v1/sys/health?standbyok=true";
                          port = 8200;
                          scheme = "HTTP";
                        };
                        initialDelaySeconds = 5;
                        periodSeconds = 5;
                      };
                    }];
                  };
                };
              };
            };
            
            service = {
              apiVersion = "v1";
              kind = "Service";
              metadata = {
                name = "vault";
                namespace = cfg.vault.namespace;
                labels."app.kubernetes.io/name" = "vault";
              };
              spec = {
                type = "ClusterIP";
                selector."app.kubernetes.io/name" = "vault";
                ports = [
                  { name = "http"; port = 8200; targetPort = 8200; protocol = "TCP"; }
                  { name = "https-internal"; port = 8201; targetPort = 8201; protocol = "TCP"; }
                ];
              };
            };
            
            allManifests = [ deployment service ];
          in
          pkgs.runCommand "vault-manifests" {} ''
            mkdir -p $out
            ${lib.concatMapStringsSep "\n" (manifest: ''
              echo "---" >> $out/manifest.yaml
              cat ${yaml.generate "manifest.yaml" manifest} >> $out/manifest.yaml
            '') allManifests}
          ''
        )];
      };
    })
    
    # External Secrets configuration (SecretStore and ExternalSecret)
    # These are deployed AFTER ESO is installed, so we expose them as a separate build output
    (mkIf cfg.externalSecrets.enable {
      build.scripts.pmm-external-secrets-manifests = pkgs.writeText "pmm-external-secrets.yaml" (
        builtins.concatStringsSep "\n---\n" [
          (builtins.readFile (yaml.generate "vault-token-secret.yaml" {
            apiVersion = "v1";
            kind = "Secret";
            metadata = {
              name = "vault-token";
              namespace = cfg.pmm.namespace;
            };
            type = "Opaque";
            stringData.token = cfg.vault.rootToken;
          }))
          (builtins.readFile (yaml.generate "secretstore.yaml" {
            apiVersion = "external-secrets.io/v1beta1";
            kind = "SecretStore";
            metadata = {
              name = "vault-backend";
              namespace = cfg.pmm.namespace;
            };
            spec = {
              provider.vault = {
                server = "http://vault.${cfg.vault.namespace}.svc.cluster.local:8200";
                path = "secret";
                version = "v2";
                auth.tokenSecretRef = {
                  name = "vault-token";
                  key = "token";
                };
              };
            };
          }))
          (builtins.readFile (yaml.generate "externalsecret.yaml" {
            apiVersion = "external-secrets.io/v1beta1";
            kind = "ExternalSecret";
            metadata = {
              name = "pmm-token";
              namespace = cfg.pmm.namespace;
            };
            spec = {
              refreshInterval = "1m";
              secretStoreRef = {
                name = "vault-backend";
                kind = "SecretStore";
              };
              target = {
                name = "pmm-token";
                creationPolicy = "Owner";
              };
              data = [{
                secretKey = "pmmservertoken";
                remoteRef = {
                  key = "pmm/wookie";
                  property = "token";
                };
              }];
            };
          }))
        ]
      );
    })
  ]);
}

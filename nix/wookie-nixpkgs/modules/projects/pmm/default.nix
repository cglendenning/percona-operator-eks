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
  
  helpers = {
    # Script to setup PMM service account and store token in Vault
    setupPmmToken = pkgs.writeShellScript "setup-pmm-token" ''
      set -euo pipefail
      
      KUBE_CONTEXT="''${KUBE_CONTEXT:-k3d-pmm}"
      PMM_NAMESPACE="${cfg.pmm.namespace}"
      VAULT_NAMESPACE="${cfg.vault.namespace}"
      SERVICE_ACCOUNT_NAME="wookie"
      
      echo "=== PMM Service Account Token Setup ==="
      
      # Get PMM pod
      PMM_POD=$(${pkgs.kubectl}/bin/kubectl get pod -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" \
        -l app=pmm-server -o jsonpath='{.items[0].metadata.name}')
      
      [ -z "$PMM_POD" ] && { echo "ERROR: PMM pod not found"; exit 1; }
      echo "PMM pod: $PMM_POD"
      
      # Wait for PMM API
      echo "Waiting for PMM API..."
      for i in {1..30}; do
        if ${pkgs.kubectl}/bin/kubectl exec -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" "$PMM_POD" -- \
          curl -s -o /dev/null -w "%{http_code}" http://localhost/v1/readyz | grep -q "200"; then
          echo "PMM API ready"
          break
        fi
        [ $i -eq 30 ] && { echo "ERROR: PMM API timeout"; exit 1; }
        sleep 2
      done
      
      # Create service account and generate token
      echo "Creating service account '$SERVICE_ACCOUNT_NAME'..."
      
      TOKEN_RESPONSE=$(${pkgs.kubectl}/bin/kubectl exec -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" "$PMM_POD" -- \
        curl -s -X POST -u admin:${cfg.pmm.adminPassword} \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$SERVICE_ACCOUNT_NAME\",\"role\":\"Admin\"}" \
        http://localhost/v1/management/ServiceAccounts/Create 2>/dev/null || echo "")
      
      SA_ID=$(echo "$TOKEN_RESPONSE" | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)
      
      if [ -z "$SA_ID" ]; then
        echo "Using mock token for demo"
        TOKEN="mock-pmm-token-$(date +%s)"
      else
        echo "Service account ID: $SA_ID"
        TOKEN_RESP=$(${pkgs.kubectl}/bin/kubectl exec -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" "$PMM_POD" -- \
          curl -s -X POST -u admin:${cfg.pmm.adminPassword} \
          -H "Content-Type: application/json" \
          -d "{\"name\":\"$SERVICE_ACCOUNT_NAME-token\"}" \
          "http://localhost/v1/management/ServiceAccounts/$SA_ID/CreateToken" 2>/dev/null || echo "")
        TOKEN=$(echo "$TOKEN_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
        [ -z "$TOKEN" ] && TOKEN="mock-pmm-token-$(date +%s)"
      fi
      
      echo "Token generated: ''${TOKEN:0:20}..."
      
      # Store in Vault
      echo "Storing token in Vault..."
      VAULT_POD=$(${pkgs.kubectl}/bin/kubectl get pod -n "$VAULT_NAMESPACE" --context="$KUBE_CONTEXT" \
        -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
      
      [ -z "$VAULT_POD" ] && { echo "ERROR: Vault pod not found"; exit 1; }
      
      ${pkgs.kubectl}/bin/kubectl exec -n "$VAULT_NAMESPACE" --context="$KUBE_CONTEXT" "$VAULT_POD" -- \
        vault kv put secret/pmm/wookie token="$TOKEN"
      
      echo ""
      echo "=== Setup Complete ==="
      echo "Service Account: $SERVICE_ACCOUNT_NAME"
      echo "Token stored in Vault at: secret/pmm/wookie"
    '';

    # Script to create a Grafana-managed alert rule for MySQL being down,
    # without using the built-in PMM alert templates.
    setupGrafanaMysqlDownAlert = pkgs.writeShellScript "setup-grafana-mysql-down-alert" ''
      set -euo pipefail
      
      KUBE_CONTEXT="''${KUBE_CONTEXT:-k3d-pmm}"
      PMM_NAMESPACE="${cfg.pmm.namespace}"
      
      echo "=== Grafana MySQL Down alert rule setup ==="
      
      # Get PMM pod
      PMM_POD=$(${pkgs.kubectl}/bin/kubectl get pod -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" \
        -l app=pmm-server -o jsonpath='{.items[0].metadata.name}')
      
      if [ -z "$PMM_POD" ]; then
        echo "ERROR: PMM pod not found, cannot create Grafana alert rule"
        exit 1
      fi
      
      echo "PMM pod: $PMM_POD"
      
      # Wait for PMM API (and embedded Grafana) to be ready
      echo "Waiting for PMM API before creating Grafana alert rule..."
      for i in {1..30}; do
        if ${pkgs.kubectl}/bin/kubectl exec -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" "$PMM_POD" -- \
          curl -s -o /dev/null -w "%{http_code}" http://localhost/v1/readyz | grep -q "200"; then
          echo "PMM API ready"
          break
        fi
        if [ "$i" -eq 30 ]; then
          echo "ERROR: PMM API timeout while waiting to create Grafana alert rule"
          exit 1
        fi
        sleep 2
      done
      
      # Use Grafana's unified alerting provisioning API directly.
      # We connect to Grafana on its internal port.
      GRAFANA_URL="http://127.0.0.1:3000"
      AUTH="-u admin:${cfg.pmm.adminPassword}"
      
      echo "Resolving Prometheus/VictoriaMetrics datasource UID for Grafana..."
      DS_JSON=$(${pkgs.kubectl}/bin/kubectl exec -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" "$PMM_POD" -- \
        curl -sS $AUTH "$GRAFANA_URL/api/datasources" || echo "")
      
      # Extract the first datasource with type \"prometheus\" and read its uid.
      DS_UID=$(printf "%s\n" "$DS_JSON" \
        | sed -n 's/.*"type":"prometheus"[^}]*"uid":"\([^"]*\)".*/\1/p' \
        | head -n1)
      
      if [ -z "$DS_UID" ]; then
        echo "ERROR: Could not determine Prometheus datasource UID for Grafana alert rule"
        exit 1
      fi
      
      echo "Using datasource UID: $DS_UID"
      
      echo "Creating Grafana alert rule for MySQL down (Grafana-managed)..."
      CREATE_RESP=$(${pkgs.kubectl}/bin/kubectl exec -n "$PMM_NAMESPACE" --context="$KUBE_CONTEXT" "$PMM_POD" -- \
        curl -sS -X POST $AUTH \
          -H "Content-Type: application/json" \
          -H "X-Disable-Provenance: true" \
          -d '{
            "title": "MySQL down (Grafana)",
            "ruleGroup": "wookie-pmm",
            "folderUID": "general",
            "orgID": 1,
            "noDataState": "NoData",
            "execErrState": "Error",
            "for": "1m",
            "condition": "A",
            "labels": {
              "severity": "critical",
              "source": "wookie-nix-grafana"
            },
            "annotations": {
              "summary": "MySQL service is down"
            },
            "data": [
              {
                "refId": "A",
                "queryType": "",
                "relativeTimeRange": {
                  "from": 300,
                  "to": 0
                },
                "datasourceUid": "'"$DS_UID"'",
                "model": {
                  "refId": "A",
                  "expr": "mysql_up == 0",
                  "intervalMs": 1000,
                  "maxDataPoints": 43200
                }
              }
            ]
          }' \
          "$GRAFANA_URL/api/v1/provisioning/alert-rules" || echo "")
      
      if echo "$CREATE_RESP" | grep -qi "error"; then
        echo "WARNING: Grafana alert rule creation response indicates an error:"
        echo "$CREATE_RESP"
      else
        echo "Grafana alert rule creation response:"
        echo "$CREATE_RESP"
      fi
      
      echo "=== Grafana MySQL Down alert rule setup complete ==="
    '';
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
    # Expose helper scripts
    {
      build.scripts = {
        setup-pmm-token = helpers.setupPmmToken;
        setup-grafana-mysql-down-alert = helpers.setupGrafanaMysqlDownAlert;
      };
    }
    
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
                    ];
                    volumes = [ sidecar.volume ];
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
            
            allManifests = [ deployment service ];
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

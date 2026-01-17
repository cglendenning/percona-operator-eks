{..
  config,
  lib,
  pkgs,
  wookietrustlib,
  ...
}:
with lib;
let
  platform = config.platform;
  cluster = platform.final.kubernetes.cluster;
  k3dClusterName = "local";

  getResourcesOfKind = (import ../transforms/traversal-helpers.nix { lib = lib; }).getResourcesOfKind;

in
{
  imports = [ ./manifests.nix ];

  options = {
    platform.final.k3d-config = mkOption {
      internal = true;
      type = types.anything;
    };
  };

  config =
    let
      registry = config.platform.config.registry.name;
      rancher-image = "rancher/k3s:v1.31.7-k3s1";
      internal-root = pkgs.wookietrust.cacert;
      agents = 3;
      servers = 1;

      k3d-cmd = "${pkgs.k3d}/bin/k3d";
      vault-cmd = "${pkgs.k3d}/bin/vault";
      allNamespaces = cluster.batches.namespaces.bundles.namespaces.objects;
      allNodePorts =  flatten ( 
        map (service: service.spec.ports) ( 
          filter (service: lib.hasAttr "type" service.spec && service.spec.type == "NodePort") ( 
            getResourcesOfKind "Service" cluster.batches
          )
        )
      );

      onlyExplicitNodePorts = filter (portSpec: lib.hasAttr "nodePort" portSpec) allNodePorts;

      nodePortMappings = map (portSpec: {
        port = "${builtins.toString portSpec.port}:${builtins.toString portSpec.nodePort}";
        nodeFilters = [ "loadbalancer" ];
      }) onlyExplicitNodePorts;

      namespaceArrayLit =
        "namespaces=(" + lib.concatStringSep " " (map (o: ''"${o.metadata.name}"'') allNamespaces) + ")";

      k3d-config = {
        apiVersion = "k3d.io/v1alpha5";
        kind = "Simple";
        metadata.name = k3dClusterName;
        servers = servers;
        agents = agents;
        image = rancher-image;
        ports = [
          {
            port = "8080:80";
            nodeFilters = [
              "loadbalancer"
            ];
          }
        ]
        ++ (builtins.deepSeq nodePortMappings nodePortMappings);
        registries = {
          create = {
            name = "nexus";
            hostPort = "45000";
          };
          config = ''
            mirrors:
              "quay.io":
                endpoint:
                  - https://${registry}

              "ghcr.io":
                endpoint:
                  - https://${registry}

              "docker.io":
                endpoint:
                  - https://${registry}

              "registry.k8s.io":
                endpoint:
                  - https://${registry}
    
              "quay.io":
                endpoint:
                  - https://${registry}

              "${registry}":
                endpoint:
                  - https://${registry}
           configs:
             ${registry}:
               auth:
                 username: $DOCKER_REGISTRY_USER
                 password: $DOCKER_REGISTRY_PASSWORD
               tls:
                 ca_file: "/etc/ssl/certs/wookietrust-internal.pem"
          '';
        };
        volumes = [
          {
            volume = "${internal-root}/etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/wookietrust-internal.pem";

          }
        ];
        options = {
          k3s = {
            extraArgs = [
              {
                arg = "--cluster-cidr=172.16.0.0/16";
                nodeFilters = [
                  "server:*"
                ];
              }
            ];
          };
        };
      };

      k3d-config-yaml = pkgs.writeText "k3d-config.yaml" (
        builtins.readFile (wookietrustlib.helpers.toYAML k3d-config)
      );
    in
    {
      platform.final.k3d-config = k3d-config;

      platform.out = {
        scripts =
          let
            helmfile = platform.out.scripts.helmfile.script;
          in
          rec {
            
            k3d-up = {
              description = "Spin up new k3d cluster.";
              script = pkgs.writeShellScriptBin "k3d-up" ''
                set -euo pipefile
                ${k3d-cmd} cluster create -c ${k3d-config-yaml} --kubeconfig-update-default=false
                ${k3d-cmd} kubeconfig merge ${k3dClusterName} --output $KUBECONFIG
                
      
              '';
            };

            k3d-down = {
              description = "Delete k3d cluster.";
              script = pkgs.writeShellScriptBin "k3d-down" ''
                ${k3d-cmd} cluster delete -c ${k3d-config-yaml}
              '';
            };

            up = {
              description = "Spin up k3d cluster if it doesn't exist and apply all k8s manifests.";
              script = pkgs.writeShellScriptBin "up" ''
                set -euo pipefail

                ${namespaceArrayLit}
                export VAULT_ADDR="https://pwvault.dev.wookietrust.com
                VAULT_TOKEN_FILE="$HOME/.vault-token"

                ${k3d-cmd} cluster list local || ${k3d-up.script}/bin/k3d-up

                if [ ! -f "$VAULT_TOKEN_FILE" ]; then
                  echo "~/.vault-token not found, running vault login..."
                  ${vault-cmd} login -method ldap
                fi

                VAULT_TOKEN="$(cat "$VAULT_TOKEN_FILE")"

                if [ -z "''${VAULT_TOKEN:-}" ]; then
                  echo "ERROR: ~/.vault-token is empty" >&2
                  exit 1
                fi

                echo "Validating Vault token..."
                if ! ${vault-cmd} token lookup >/dev/null 2>&1; then
                  echo "ERROR: Vault token is invalid or expired. Please re-authenticate." >&2
                  echo "Removing invalid token and re-authenticating..."
                  rm -f "$VAULT_TOKEN_FILE"
                  ${vault-cmd} login -method ldap
                  VAULT_TOKEN="$(cat "$VAULT_TOKEN_FILE")"

                  if [ -z "''${VAULT_TOKEN:-}" ]; then
                    echo "ERROR: Failed to obtain valid Vault token' >&2
                    exit 1
                  fi
                else
                  echo "Vault token is valid."
                fi 

                ${helmfile}/bin/helmfile -l name=namespaces-b-namespaces sync

                missing=()

                for ns in "''${namespaces[@]}"; do
                  if ! ${pkgs.kubectl}/bin/kubectl get ns "$ns" >/dev/null 2>&1; then
                    echo "WARNING: namespace '$ns' does not exist yet, skipping Secret creation." >&2
                    missing+=("$ns")
                    continue
                  fi

                  ${pkgs.kubectl}/bin/kubectl -n "$ns" create secret generic vault-token \
                    --from-literal-token="$VAULT_TOKEN" \
                    --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -
                done

                ${helmfile}/bin/helmfile sync
              '';
            };
          };
      };
    };
}

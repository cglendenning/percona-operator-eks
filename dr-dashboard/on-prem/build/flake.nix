{
  description = "DR Dashboard On-Prem Kubernetes manifests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Simple YAML serializer for Kubernetes manifests
        toYAML = value:
          let
            indent = depth: lib.concatStrings (lib.genList (_: "  ") depth);

            serialize = depth: val:
              if val == null then "null"
              else if val == true then "true"
              else if val == false then "false"
              else if lib.isInt val then toString val
              else if lib.isString val then
                if lib.hasInfix "\n" val then
                  "|\n" + lib.concatMapStringsSep "\n" (line: "${indent (depth + 1)}${line}") (lib.splitString "\n" val)
                else if val == "" then "\"\""
                else if builtins.match "^[a-zA-Z0-9_./-]+$" val != null then val
                else "\"${lib.escape ["\"" "\\"] val}\""
              else if lib.isList val then
                if val == [] then "[]"
                else "\n" + lib.concatMapStringsSep "\n" (item:
                  "${indent depth}- ${serialize (depth + 1) item}"
                ) val
              else if lib.isAttrs val then
                if val == {} then "{}"
                else "\n" + lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v:
                  let
                    serialized = serialize (depth + 1) v;
                    needsNewline = lib.isAttrs v && v != {} || lib.isList v && v != [];
                  in
                  "${indent depth}${k}:${if needsNewline then serialized else " ${serialized}"}"
                ) val)
              else toString val;
          in
          lib.removePrefix "\n" (serialize 0 value);

        # Generate manifests directly
        generateManifests = {
          registry ? "",
          imageTag ? "latest",
          namespace ? "default",
          serviceType ? "ClusterIP",
          nodePort ? null,
          ingressHost ? "wookie.eko.dev.cookie.com",
          ingressEnabled ? true,
          ingressClassName ? null,
          ingressTlsEnabled ? false,
          ingressTlsSecretName ? "dr-dashboard-tls",
          resourceRequestsMemory ? "32Mi",
          resourceRequestsCpu ? "10m",
          resourceLimitsMemory ? "128Mi",
          resourceLimitsCpu ? "100m"
        }:
          let
            # Build full image reference
            imageRef =
              if registry != ""
              then "${registry}/dr-dashboard-on-prem:${imageTag}"
              else "dr-dashboard-on-prem:${imageTag}";

            # Common labels
            labels = {
              app = "dr-dashboard";
              environment = "on-prem";
            };

            # Deployment manifest
            deployment = {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = {
                name = "dr-dashboard-on-prem";
                inherit namespace labels;
              };
              spec = {
                replicas = 1;
                selector.matchLabels = {
                  app = "dr-dashboard";
                  environment = "on-prem";
                };
                template = {
                  metadata.labels = labels;
                  spec = {
                    containers = [{
                      name = "dr-dashboard";
                      image = imageRef;
                      imagePullPolicy = if registry != "" then "Always" else "IfNotPresent";
                      ports = [{
                        containerPort = 8080;
                        name = "http";
                      }];
                      env = [
                        { name = "PORT"; value = "8080"; }
                        { name = "DATA_DIR"; value = "/app/data"; }
                        { name = "STATIC_DIR"; value = "/app/static"; }
                      ];
                      resources = {
                        requests = {
                          memory = resourceRequestsMemory;
                          cpu = resourceRequestsCpu;
                        };
                        limits = {
                          memory = resourceLimitsMemory;
                          cpu = resourceLimitsCpu;
                        };
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "/";
                          port = "http";
                        };
                        initialDelaySeconds = 5;
                        periodSeconds = 30;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/";
                          port = "http";
                        };
                        initialDelaySeconds = 3;
                        periodSeconds = 10;
                      };
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 1000;
                        readOnlyRootFilesystem = true;
                        allowPrivilegeEscalation = false;
                      };
                    }];
                    securityContext = {
                      fsGroup = 1000;
                    };
                  };
                };
              };
            };

            # Service manifest
            servicePort = {
              port = 80;
              targetPort = "http";
              protocol = "TCP";
              name = "http";
            } // lib.optionalAttrs (serviceType == "NodePort" && nodePort != null) {
              inherit nodePort;
            };

            service = {
              apiVersion = "v1";
              kind = "Service";
              metadata = {
                name = "dr-dashboard-on-prem";
                inherit namespace labels;
              };
              spec = {
                type = serviceType;
                ports = [ servicePort ];
                selector = {
                  app = "dr-dashboard";
                  environment = "on-prem";
                };
              };
            };

            # Ingress manifest
            ingress = lib.optionalAttrs (ingressEnabled && ingressHost != "") {
              apiVersion = "networking.k8s.io/v1";
              kind = "Ingress";
              metadata = {
                name = "dr-dashboard-on-prem";
                inherit namespace labels;
              };
              spec = {
                rules = [{
                  host = ingressHost;
                  http = {
                    paths = [{
                      path = "/";
                      pathType = "Prefix";
                      backend = {
                        service = {
                          name = "dr-dashboard-on-prem";
                          port = {
                            name = "http";
                          };
                        };
                      };
                    }];
                  };
                }];
              } // lib.optionalAttrs (ingressClassName != null) {
                ingressClassName = ingressClassName;
              } // lib.optionalAttrs ingressTlsEnabled {
                tls = [{
                  hosts = [ ingressHost ];
                  secretName = ingressTlsSecretName;
                }];
              };
            };

            # Collect all manifests
            allManifests = { inherit deployment service; }
              // lib.optionalAttrs (ingressEnabled && ingressHost != "") { inherit ingress; };

            # Convert to YAML
            yamlDocs = lib.mapAttrsToList
              (name: manifest: "---\n# ${name}\n${toYAML manifest}")
              allManifests;

          in
          builtins.concatStringsSep "\n" yamlDocs;

        # Build manifest derivation
        buildManifests = args:
          pkgs.writeTextFile {
            name = "dr-dashboard-manifests";
            text = generateManifests args;
            destination = "/manifests.yaml";
          };

        # Default configuration
        defaultArgs = {
          registry = "";
          imageTag = "latest";
          namespace = "default";
          serviceType = "ClusterIP";
          ingressEnabled = true;
          ingressHost = "wookie.eko.dev.cookie.com";
        };

      in
      {
        # Packages
        packages = {
          default = buildManifests defaultArgs;

          local = buildManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            serviceType = "ClusterIP";
            ingressEnabled = true;
            ingressHost = "wookie.eko.dev.cookie.com";
          };

          nodeport = buildManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            serviceType = "NodePort";
            nodePort = 30080;
            ingressEnabled = false;
          };

          tls = buildManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            serviceType = "ClusterIP";
            ingressEnabled = true;
            ingressHost = "wookie.eko.dev.cookie.com";
            ingressTlsEnabled = true;
          };
        };

        # Dev shell with kubectl and useful tools
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            kubectl
            kubernetes-helm
            yq-go
          ];
        };

        # Lib functions for programmatic use
        lib = {
          inherit generateManifests buildManifests;
        };
      }
    );
}

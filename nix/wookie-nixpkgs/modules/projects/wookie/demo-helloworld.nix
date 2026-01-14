{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.projects.wookie.demo-helloworld;

in
{
  options.projects.wookie.demo-helloworld = {
    enable = mkEnableOption "Demo helloworld application for multi-cluster testing";

    namespace = mkOption {
      type = types.str;
      default = "demo";
      description = "Namespace for the helloworld application.";
    };

    replicas = mkOption {
      type = types.int;
      default = 3;
      description = "Number of helloworld replicas.";
    };

    version = mkOption {
      type = types.str;
      default = "v1";
      description = "Version label for the helloworld application.";
    };

    image = mkOption {
      type = types.str;
      default = "docker.io/istio/examples-helloworld-v1";
      description = "Container image for helloworld.";
    };
  };

  config = mkIf cfg.enable {
    # Create namespace
    platform.kubernetes.cluster.batches.namespaces.bundles."helloworld-namespace" = {
      namespace = cfg.namespace;
      manifests = [
        (let
          yaml = pkgs.formats.yaml { };
          resource = {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = cfg.namespace;
              labels = {
                "istio-injection" = "enabled";
              };
            };
          };
        in
        pkgs.runCommand "helloworld-namespace" {} ''
          mkdir -p $out
          cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
        '')
      ];
    };

    # Deploy helloworld service and statefulset
    platform.kubernetes.cluster.batches.services.bundles.helloworld = {
      namespace = cfg.namespace;
      manifests = [
        (let
          yaml = pkgs.formats.yaml { };
          
          service = {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "helloworld";
              namespace = cfg.namespace;
              labels = {
                app = "helloworld";
                service = "helloworld";
              };
            };
            spec = {
              ports = [
                {
                  port = 5000;
                  name = "http";
                }
              ];
              selector = {
                app = "helloworld";
              };
            };
          };
          
          deployment = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "helloworld-${cfg.version}";
              namespace = cfg.namespace;
              labels = {
                app = "helloworld";
                version = cfg.version;
              };
            };
            spec = {
              replicas = cfg.replicas;
              selector = {
                matchLabels = {
                  app = "helloworld";
                  version = cfg.version;
                };
              };
              template = {
                metadata = {
                  labels = {
                    app = "helloworld";
                    version = cfg.version;
                  };
                };
                spec = {
                  containers = [
                    {
                      name = "helloworld";
                      image = cfg.image;
                      resources = {
                        requests = {
                          cpu = "100m";
                        };
                      };
                      imagePullPolicy = "IfNotPresent";
                      ports = [
                        {
                          containerPort = 5000;
                        }
                      ];
                      env = [
                        {
                          name = "SERVICE_VERSION";
                          value = cfg.version;
                        }
                      ];
                    }
                  ];
                };
              };
            };
          };
          
          serviceYaml = yaml.generate "service.yaml" service;
          deploymentYaml = yaml.generate "deployment.yaml" deployment;
        in
        pkgs.runCommand "helloworld-app" {} ''
          mkdir -p $out
          cat ${serviceYaml} > $out/manifest.yaml
          echo "---" >> $out/manifest.yaml
          cat ${deploymentYaml} >> $out/manifest.yaml
        '')
      ];
      # Note: Namespaces are created via kubectl before helmfile runs
      # Dependencies on other services are handled by batch-level ordering
    };
  };
}

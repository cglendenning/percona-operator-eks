# Profile: SeaweedFS Tutorial - Two namespace replication setup
# This profile configures SeaweedFS in two namespaces for replication testing

[
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "seaweedfs-tutorial";
    };

    platform.kubernetes.cluster = {
      uniqueIdentifier = "seaweedfs-tutorial";
      
      defaults = {
        ingress = null;
        clusterIssuer = null;
      };

      batches = {
        namespaces = {
          priority = 100;
          bundles = {
            namespace-primary = {
              namespace = "seaweedfs-primary";
              manifests = [
                (let
                  yaml = pkgs.formats.yaml {};
                  ns = {
                    apiVersion = "v1";
                    kind = "Namespace";
                    metadata.name = "seaweedfs-primary";
                  };
                in
                pkgs.runCommand "seaweedfs-primary-namespace" {} ''
                  mkdir -p $out
                  cp ${yaml.generate "manifest.yaml" ns} $out/manifest.yaml
                '')
              ];
            };
            namespace-secondary = {
              namespace = "seaweedfs-secondary";
              manifests = [
                (let
                  yaml = pkgs.formats.yaml {};
                  ns = {
                    apiVersion = "v1";
                    kind = "Namespace";
                    metadata.name = "seaweedfs-secondary";
                  };
                in
                pkgs.runCommand "seaweedfs-secondary-namespace" {} ''
                  mkdir -p $out
                  cp ${yaml.generate "manifest.yaml" ns} $out/manifest.yaml
                '')
              ];
            };
          };
        };

        services = {
          priority = 600;
          bundles = {
            seaweedfs-primary = {
              namespace = "seaweedfs-primary";
              chart = {
                name = "seaweedfs";
                version = "4_0_406";
                package = (import ../../pkgs/charts/charts.nix { 
                  kubelib = pkgs.kubelib;
                  inherit lib;
                }).seaweedfs."4_0_406";
                values = {
                  master = {
                    enabled = true;
                    replicas = 1;
                  };
                  volume = {
                    enabled = true;
                    replicas = 1;
                    persistence = {
                      enabled = true;
                      storageClass = "local-path";
                      size = "10Gi";
                    };
                  };
                  filer = {
                    enabled = true;
                    replicas = 1;
                    s3 = {
                      enabled = true;
                      enableAuth = false;
                    };
                    extraEnvironmentVars = {
                      WEED_REPLICATION = "001";
                    };
                  };
                };
              };
            };
            seaweedfs-secondary = {
              namespace = "seaweedfs-secondary";
              dependsOn = [ "seaweedfs-primary" ];
              chart = {
                name = "seaweedfs";
                version = "4_0_406";
                package = (import ../../pkgs/charts/charts.nix { 
                  kubelib = pkgs.kubelib;
                  inherit lib;
                }).seaweedfs."4_0_406";
                values = {
                  master = {
                    enabled = true;
                    replicas = 1;
                  };
                  volume = {
                    enabled = true;
                    replicas = 1;
                    persistence = {
                      enabled = true;
                      storageClass = "local-path";
                      size = "10Gi";
                    };
                  };
                  filer = {
                    enabled = true;
                    replicas = 1;
                    s3 = {
                      enabled = true;
                      enableAuth = false;
                    };
                    extraEnvironmentVars = {
                      WEED_REPLICATION = "001";
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  }
]

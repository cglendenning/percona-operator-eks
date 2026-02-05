# Profile: SeaweedFS Active-Passive Replication
# Demonstrates configuring active-passive filer sync between two SeaweedFS namespaces

{ pkgs, lib, ... }:

[
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "swfs-repl";  # Short name to keep Helm release names under 53 chars
      apiPort = 6444;  # Use different port to avoid conflicts
    };

    platform.kubernetes.cluster = let
      charts = import ../../pkgs/charts/charts.nix { 
        kubelib = pkgs.kubelib;
        inherit lib;
      };
      seaweedfsChart = charts.seaweedfs."4_0_406";
    in {
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
                package = seaweedfsChart;
                values = {
                  global = {
                    enableSecurity = false;
                  };
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
              chart = {
                name = "seaweedfs";
                version = "4_0_406";
                package = seaweedfsChart;
                values = {
                  master = {
                    enabled = true;
                    replicas = 1;
                    # Disable security features that use fromToml
                    config = "";
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
                    # Disable security features that use fromToml
                    config = "";
                  };
                  # Disable global security config
                  global = {
                    enableSecurity = false;
                  };
                };
              };
            };
          };
        };
      };
    };

    # Configure active-passive replication from primary to secondary
    platform.seaweedfs.filerSync = {
      enable = true;
      syncPairs = [
        {
          name = "p2s";  # Short name: primary-to-secondary
          namespace = "seaweedfs-primary";
          activePassive = true;
          dependsOn = [ "seaweedfs-primary" "seaweedfs-secondary" ];
          
          filerA = {
            host = "seaweedfs-filer.seaweedfs-primary.svc.cluster.local";
            port = 8888;
            path = null;  # Sync all paths
            useFilerProxy = false;
            debug = false;
          };
          
          filerB = {
            host = "seaweedfs-filer.seaweedfs-secondary.svc.cluster.local";
            port = 8888;
            path = null;  # Sync all paths
            useFilerProxy = false;
            debug = false;
          };
          
          image = "chrislusf/seaweedfs:latest";
          
          resources = {
            requests = {
              cpu = "100m";
              memory = "128Mi";
            };
            limits = {
              cpu = "500m";
              memory = "512Mi";
            };
          };
        }
      ];
    };
  }
]

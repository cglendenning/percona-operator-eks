# Profile: SeaweedFS Tutorial - Two namespace replication setup
# This profile configures SeaweedFS in two namespaces for replication testing

{ pkgs, lib, ... }:

[
  ../targets/local-k3d.nix
  {
    targets.local-k3d = {
      enable = true;
      clusterName = "swfs-repl";
      apiPort = 6444;
    };

    platform.kubernetes.cluster = let
      mkSeaweedFS = import ../../modules/platform/seaweedfs/minimal-deployment.nix { inherit pkgs lib; };
    in {
      # uniqueIdentifier is set by local-k3d target module
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
              manifests = [
                (mkSeaweedFS {
                  name = "seaweedfs";
                  namespace = "seaweedfs-primary";
                  image = "chrislusf/seaweedfs:latest";
                  replicas = 1;
                })
              ];
            };
            seaweedfs-secondary = {
              namespace = "seaweedfs-secondary";
              manifests = [
                (mkSeaweedFS {
                  name = "seaweedfs";
                  namespace = "seaweedfs-secondary";
                  image = "chrislusf/seaweedfs:latest";
                  replicas = 1;
                })
              ];
            };
          };
        };
      };
    };

    # Configure active-passive replication from primary to secondary
    platform.seaweedfs.filerSync = {
      enable = true;
      syncPairs = [{
        name = "p2s";
        namespace = "seaweedfs-primary";
        activePassive = true;
        dependsOn = [ "seaweedfs-primary" "seaweedfs-secondary" ];
        
        filerA = {
          host = "seaweedfs-filer.seaweedfs-primary.svc.cluster.local";
          port = 8888;
        };
        
        filerB = {
          host = "seaweedfs-filer.seaweedfs-secondary.svc.cluster.local";
          port = 8888;
        };
        
        image = "chrislusf/seaweedfs:latest";
      }];
    };
  }
]

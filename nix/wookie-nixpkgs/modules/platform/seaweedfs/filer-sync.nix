# SeaweedFS Filer Sync Module
# Configures active-passive or active-active cross-cluster filer synchronization
# Uses weed filer.sync command as a Kubernetes Deployment

{ pkgs, lib, config, ... }:
with lib;

let
  cfg = config.platform.seaweedfs.filerSync;
  yaml = pkgs.formats.yaml {};
  
  mkSyncDeployment = syncConfig:
    let
      # Build command args
      baseArgs = [
        "-a" "${syncConfig.filerA.host}:${toString syncConfig.filerA.port}"
        "-b" "${syncConfig.filerB.host}:${toString syncConfig.filerB.port}"
      ];
      
      pathArgs = 
        (optional (syncConfig.filerA.path != null) "-a.path=${syncConfig.filerA.path}") ++
        (optional (syncConfig.filerB.path != null) "-b.path=${syncConfig.filerB.path}");
      
      modeArgs = optional syncConfig.activePassive "-isActivePassive";
      
      proxyArgs =
        (optional syncConfig.filerA.useFilerProxy "-a.filerProxy") ++
        (optional syncConfig.filerB.useFilerProxy "-b.filerProxy");
      
      debugArgs =
        (optional syncConfig.filerA.debug "-a.debug") ++
        (optional syncConfig.filerB.debug "-b.debug");
      
      allArgs = baseArgs ++ pathArgs ++ modeArgs ++ proxyArgs ++ debugArgs;
      
      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = syncConfig.name;
          namespace = syncConfig.namespace;
          labels = {
            app = "seaweedfs-filer-sync";
            "sync-pair" = syncConfig.name;
          };
        };
        spec = {
          replicas = 1;
          selector.matchLabels = {
            app = "seaweedfs-filer-sync";
            "sync-pair" = syncConfig.name;
          };
          template = {
            metadata.labels = {
              app = "seaweedfs-filer-sync";
              "sync-pair" = syncConfig.name;
            };
            spec = {
              containers = [{
                name = "filer-sync";
                image = syncConfig.image;
                command = [ "weed" "filer.sync" ] ++ allArgs;
                resources = syncConfig.resources;
                env = syncConfig.extraEnv;
              }];
              restartPolicy = "Always";
            };
          };
        };
      };
    in
    pkgs.runCommand "seaweedfs-filer-sync-${syncConfig.name}" {} ''
      mkdir -p $out
      cp ${yaml.generate "manifest.yaml" deployment} $out/manifest.yaml
    '';

in
{
  options.platform.seaweedfs.filerSync = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable SeaweedFS filer synchronization between clusters.";
    };
    
    syncPairs = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Name for this sync pair (used as deployment name).";
            example = "cluster-a-to-cluster-b";
          };
          
          namespace = mkOption {
            type = types.str;
            description = "Kubernetes namespace to deploy the sync pod.";
            example = "seaweedfs";
          };
          
          activePassive = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Enable active-passive mode (one-way replication from A to B).
              If false, enables active-active bi-directional sync.
            '';
          };
          
          filerA = mkOption {
            type = types.submodule {
              options = {
                host = mkOption {
                  type = types.str;
                  description = "Filer A hostname or service name.";
                  example = "seaweedfs-filer.seaweedfs-primary.svc.cluster.local";
                };
                
                port = mkOption {
                  type = types.port;
                  default = 8888;
                  description = "Filer A port.";
                };
                
                path = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Specific path to sync from filer A (null means all paths).";
                  example = "/data/shared";
                };
                
                useFilerProxy = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Transfer files through filer instead of directly to volume servers.";
                };
                
                debug = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable debug logging for filer A transfers.";
                };
              };
            };
            description = "Source filer configuration.";
          };
          
          filerB = mkOption {
            type = types.submodule {
              options = {
                host = mkOption {
                  type = types.str;
                  description = "Filer B hostname or service name.";
                  example = "seaweedfs-filer.seaweedfs-secondary.svc.cluster.local";
                };
                
                port = mkOption {
                  type = types.port;
                  default = 8888;
                  description = "Filer B port.";
                };
                
                path = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Specific path to sync to filer B (null means all paths).";
                  example = "/data/shared";
                };
                
                useFilerProxy = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Transfer files through filer instead of directly to volume servers.";
                };
                
                debug = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable debug logging for filer B transfers.";
                };
              };
            };
            description = "Destination filer configuration.";
          };
          
          image = mkOption {
            type = types.str;
            default = "chrislusf/seaweedfs:latest";
            description = "SeaweedFS container image to use for sync pod.";
          };
          
          resources = mkOption {
            type = types.attrs;
            default = {
              requests = {
                cpu = "100m";
                memory = "128Mi";
              };
              limits = {
                cpu = "500m";
                memory = "512Mi";
              };
            };
            description = "Resource requests and limits for sync pod.";
          };
          
          extraEnv = mkOption {
            type = types.listOf types.attrs;
            default = [];
            description = "Extra environment variables for the sync container.";
            example = [
              { name = "WEED_LEVELDB_ENABLED"; value = "false"; }
            ];
          };
          
          dependsOn = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "List of bundle names this sync job depends on.";
            example = [ "seaweedfs-primary" "seaweedfs-secondary" ];
          };
        };
      });
      default = [];
      description = "List of filer sync pair configurations.";
    };
  };
  
  config = mkIf cfg.enable {
    platform.kubernetes.cluster.batches.services.bundles = 
      listToAttrs (map (syncConfig: {
        name = "seaweedfs-sync-${syncConfig.name}";
        value = {
          namespace = syncConfig.namespace;
          manifests = [ (mkSyncDeployment syncConfig) ];
          enabled = true;
          dependsOn = syncConfig.dependsOn;
        };
      }) cfg.syncPairs);
  };
}

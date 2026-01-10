{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

{
  imports = [
    ./istio.nix
  ];

  options.projects.wookie = {
    enable = mkEnableOption "Wookie project (PXC + Istio multi-cluster)";

    namespace = mkOption {
      type = types.str;
      default = "wookie";
      description = "Primary namespace for Wookie project resources.";
    };

    drNamespace = mkOption {
      type = types.str;
      default = "wookie-dr";
      description = "Disaster recovery namespace for Wookie project.";
    };

    clusterRole = mkOption {
      type = types.enum [ "primary" "dr" "standalone" ];
      default = "standalone";
      description = ''
        Role of this cluster in multi-cluster setup:
        - primary: Main production cluster
        - dr: Disaster recovery cluster
        - standalone: Single cluster deployment
      '';
    };
  };

  config = mkIf config.projects.wookie.enable {
    # Create wookie namespace
    platform.kubernetes.cluster.batches.namespaces.bundles.wookie-namespace = {
      namespace = config.projects.wookie.namespace;
      manifests = [
        (pkgs.writeTextFile {
          name = "wookie-namespace";
          text = ''
            apiVersion: v1
            kind: Namespace
            metadata:
              name: ${config.projects.wookie.namespace}
              labels:
                istio-injection: enabled
                wookie.io/cluster-role: ${config.projects.wookie.clusterRole}
          '';
        })
      ];
    };

    # Create wookie-dr namespace if in multi-cluster mode
    platform.kubernetes.cluster.batches.namespaces.bundles.wookie-dr-namespace = mkIf (config.projects.wookie.clusterRole != "standalone") {
      namespace = config.projects.wookie.drNamespace;
      manifests = [
        (pkgs.writeTextFile {
          name = "wookie-dr-namespace";
          text = ''
            apiVersion: v1
            kind: Namespace
            metadata:
              name: ${config.projects.wookie.drNamespace}
              labels:
                istio-injection: enabled
                wookie.io/cluster-role: ${config.projects.wookie.clusterRole}
          '';
        })
      ];
    };

    # Enable Istio by default for Wookie project
    projects.wookie.istio.enable = mkDefault true;
  };
}

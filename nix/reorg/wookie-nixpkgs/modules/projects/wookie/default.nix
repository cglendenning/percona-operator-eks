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
    ./demo-helloworld.nix
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
        (let
          yaml = pkgs.formats.yaml { };
          resource = {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = config.projects.wookie.namespace;
              labels = {
                "istio-injection" = "enabled";
                "wookie.io/cluster-role" = config.projects.wookie.clusterRole;
              };
            };
          };
        in
        pkgs.runCommand "wookie-namespace" {} ''
          mkdir -p $out
          cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
        '')
      ];
    };

    # Create wookie-dr namespace if in multi-cluster mode
    platform.kubernetes.cluster.batches.namespaces.bundles.wookie-dr-namespace = mkIf (config.projects.wookie.clusterRole != "standalone") {
      namespace = config.projects.wookie.drNamespace;
      manifests = [
        (let
          yaml = pkgs.formats.yaml { };
          resource = {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = config.projects.wookie.drNamespace;
              labels = {
                "istio-injection" = "enabled";
                "wookie.io/cluster-role" = config.projects.wookie.clusterRole;
              };
            };
          };
        in
        pkgs.runCommand "wookie-dr-namespace" {} ''
          mkdir -p $out
          cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
        '')
      ];
    };

    # Enable Istio by default for Wookie project
    projects.wookie.istio.enable = mkDefault true;
  };
}

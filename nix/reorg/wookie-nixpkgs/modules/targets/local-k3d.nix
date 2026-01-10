{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

{
  options.targets.local-k3d = {
    enable = mkEnableOption "Local k3d cluster target";

    clusterName = mkOption {
      type = types.str;
      default = "istio-local";
      description = "Name of the k3d cluster.";
    };

    apiPort = mkOption {
      type = types.int;
      default = 6443;
      description = "Port to expose the Kubernetes API server.";
    };

    servers = mkOption {
      type = types.int;
      default = 1;
      description = "Number of server nodes.";
    };

    agents = mkOption {
      type = types.int;
      default = 2;
      description = "Number of agent nodes.";
    };

    disableTraefik = mkOption {
      type = types.bool;
      default = true;
      description = "Disable Traefik ingress controller (recommended for Istio).";
    };

    context = mkOption {
      type = types.str;
      default = "k3d-${config.targets.local-k3d.clusterName}";
      description = "Kubectl context name for this cluster.";
    };
  };

  config = mkIf config.targets.local-k3d.enable {
    platform.kubernetes.cluster = {
      uniqueIdentifier = "local-k3d-${config.targets.local-k3d.clusterName}";
      
      defaults = {
        ingress = null;
        clusterIssuer = null;
      };
    };

    # Generate k3d cluster creation script
    build.scripts.create-cluster = pkgs.writeShellScript "create-k3d-cluster" ''
      set -euo pipefail
      
      CLUSTER_NAME="${config.targets.local-k3d.clusterName}"
      API_PORT="${toString config.targets.local-k3d.apiPort}"
      SERVERS="${toString config.targets.local-k3d.servers}"
      AGENTS="${toString config.targets.local-k3d.agents}"
      
      echo "Creating k3d cluster: $CLUSTER_NAME"
      
      ${pkgs.k3d}/bin/k3d cluster create "$CLUSTER_NAME" \
        --servers "$SERVERS" \
        --agents "$AGENTS" \
        --api-port "$API_PORT" \
        ${optionalString config.targets.local-k3d.disableTraefik ''--k3s-arg "--disable=traefik@server:*"''}
      
      echo ""
      echo "Cluster created successfully!"
      echo "Context: ${config.targets.local-k3d.context}"
      echo ""
      echo "Verify with: kubectl cluster-info --context ${config.targets.local-k3d.context}"
    '';

    # Generate k3d cluster deletion script
    build.scripts.delete-cluster = pkgs.writeShellScript "delete-k3d-cluster" ''
      set -euo pipefail
      
      CLUSTER_NAME="${config.targets.local-k3d.clusterName}"
      
      echo "Deleting k3d cluster: $CLUSTER_NAME"
      ${pkgs.k3d}/bin/k3d cluster delete "$CLUSTER_NAME" || echo "Cluster not found or already deleted"
      echo "Cleanup complete"
    '';
  };
}

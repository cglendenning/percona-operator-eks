# k3d cluster management module
#
# Provides functions for managing k3d clusters
# Exports: mkClusterConfig, mkClusterScript
{ pkgs }:

let
  yaml = pkgs.formats.yaml { };
in
{
  # Generate k3d cluster configuration
  mkClusterConfig = {
    name ? "local",
    servers ? 1,
    agents ? 2,
    ports ? [
      { port = "80:80"; nodeFilters = [ "loadbalancer" ]; }
      { port = "443:443"; nodeFilters = [ "loadbalancer" ]; }
    ],
    k3sServerArgs ? [
      "--disable=traefik"
    ],
  }:
    let
      config = {
        apiVersion = "k3d.io/v1alpha5";
        kind = "Simple";
        metadata = { inherit name; };
        inherit servers agents ports;
        options = {
          k3s = {
            extraArgs = map (arg: {
              arg = arg;
              nodeFilters = [ "server:*" ];
            }) k3sServerArgs;
          };
        };
      };
    in
    pkgs.runCommand "k3d-config" { } ''
      mkdir -p $out
      cat ${yaml.generate "config.yaml" config} > $out/k3d-config.yaml
    '';

  # Generate cluster management scripts
  mkClusterScript = {
    name ? "local",
    configPath ? null,
  }:
    let
      createScript = pkgs.writeShellScriptBin "k3d-create" ''
        set -euo pipefail
        
        if ${pkgs.k3d}/bin/k3d cluster list | grep -q "^${name}"; then
          echo "Cluster '${name}' already exists"
          exit 0
        fi
        
        echo "Creating k3d cluster '${name}'..."
        ${if configPath != null then
          "${pkgs.k3d}/bin/k3d cluster create --config ${configPath}/k3d-config.yaml"
        else
          "${pkgs.k3d}/bin/k3d cluster create ${name}"
        }
        
        echo "Waiting for cluster to be ready..."
        ${pkgs.kubectl}/bin/kubectl wait --for=condition=Ready nodes --all --timeout=120s
        
        echo "Cluster '${name}' is ready!"
      '';

      deleteScript = pkgs.writeShellScriptBin "k3d-delete" ''
        set -euo pipefail
        
        if ! ${pkgs.k3d}/bin/k3d cluster list | grep -q "^${name}"; then
          echo "Cluster '${name}' does not exist"
          exit 0
        fi
        
        echo "Deleting k3d cluster '${name}'..."
        ${pkgs.k3d}/bin/k3d cluster delete ${name}
        echo "Cluster '${name}' deleted"
      '';

      statusScript = pkgs.writeShellScriptBin "k3d-status" ''
        set -euo pipefail
        
        echo "=== k3d Clusters ==="
        ${pkgs.k3d}/bin/k3d cluster list
        
        if ${pkgs.k3d}/bin/k3d cluster list | grep -q "^${name}"; then
          echo ""
          echo "=== Cluster Nodes ==="
          ${pkgs.kubectl}/bin/kubectl get nodes -o wide
          
          echo ""
          echo "=== System Pods ==="
          ${pkgs.kubectl}/bin/kubectl get pods -A
        fi
      '';
    in
    pkgs.symlinkJoin {
      name = "k3d-scripts";
      paths = [ createScript deleteScript statusScript ];
    };
}

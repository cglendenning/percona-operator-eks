# Example: Single-cluster Wookie deployment with Istio on local k3d
#
# This configuration creates a local k3d cluster with Wookie project (Istio + future PXC).
#
# Usage:
#   nix build -f examples/single-cluster-istio.nix
#   nix run -f examples/single-cluster-istio.nix create-cluster

let
  nixpkgs = import <nixpkgs> {};
  wookie = import ../. {};
in

wookie.lib.evalModules {
  modules = [
    ../modules/platform/kubernetes
    ../modules/projects/wookie
    ../modules/targets/local-k3d.nix
    
    {
      # Configure the local k3d cluster
      targets.local-k3d = {
        enable = true;
        clusterName = "wookie-demo";
        apiPort = 6443;
        servers = 1;
        agents = 2;
      };

      # Configure Wookie project
      projects.wookie = {
        enable = true;
        namespace = "wookie";
        clusterRole = "standalone";

        # Istio component configuration
        istio = {
          enable = true;
          version = "1_24_2";
          namespace = "istio-system";
          profile = "default";

          # Customize Istio components
          base.enabled = true;
          
          istiod = {
            enabled = true;
            values = {
              pilot = {
                autoscaleEnabled = false;
              };
            };
          };

          gateway = {
            enabled = false;  # Don't need gateway for basic demo
          };

          eastWestGateway = {
            enabled = false;  # Only needed for multi-cluster
          };
        };
      };

      # Set the cluster identifier
      platform.kubernetes.cluster.uniqueIdentifier = "wookie-demo-local";
    }
  ];
}

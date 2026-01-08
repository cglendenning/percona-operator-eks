{
  description = "k3d cluster with Istio and other services";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    k3d.url = "path:./modules/k3d";
    helm.url = "path:./modules/helm";
    istio.url = "path:./modules/istio";
  };

  outputs = { self, nixpkgs, k3d, helm, istio }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Configuration
      clusterName = "local";
      istioNamespace = "istio-system";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          k3dLib = k3d.lib { inherit pkgs; };
          helmLib = helm.lib { inherit pkgs; };
          istioLib = istio.lib { inherit pkgs; };
        in
        {
          # k3d cluster configuration
          k3d-config = k3dLib.mkClusterConfig {
            name = clusterName;
            servers = 1;
            agents = 2;
            ports = [
              { host = "80"; container = "80"; nodeFilters = [ "loadbalancer" ]; }
              { host = "443"; container = "443"; nodeFilters = [ "loadbalancer" ]; }
            ];
            options = {
              k3s-server-arg = [
                "--disable=traefik"  # Disable Traefik since we're using Istio
              ];
            };
          };

          # k3d cluster management scripts
          k3d-scripts = k3dLib.mkClusterScript {
            name = clusterName;
            configPath = self.packages.${system}.k3d-config;
          };

          # Istio base (CRDs)
          istio-base = istioLib.mkIstioBase {
            namespace = istioNamespace;
            values = istioLib.defaultValues.base;
          };

          # Istiod (control plane)
          istio-istiod = istioLib.mkIstiod {
            namespace = istioNamespace;
            values = istioLib.defaultValues.istiod;
          };

          # Istio ingress gateway
          istio-gateway = istioLib.mkIstioGateway {
            namespace = istioNamespace;
            values = istioLib.defaultValues.gateway;
          };

          # Combined Istio manifests
          istio-all = pkgs.runCommand "istio-all" { } ''
            mkdir -p $out
            
            echo "# Istio Base (CRDs)" > $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-base}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istiod (Control Plane)" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-istiod}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istio Gateway" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-gateway}/manifest.yaml >> $out/manifest.yaml
          '';

          # Environment with all tools needed
          devShell = pkgs.mkShell {
            buildInputs = [
              pkgs.k3d
              pkgs.kubectl
              pkgs.kubernetes-helm
              pkgs.istioctl
              self.packages.${system}.k3d-scripts
            ];

            shellHook = ''
              echo "k3d + Istio development environment"
              echo ""
              echo "Available commands:"
              echo "  k3d-create  - Create k3d cluster"
              echo "  k3d-delete  - Delete k3d cluster"
              echo "  k3d-status  - Show cluster status"
              echo "  kubectl     - Kubernetes CLI"
              echo "  helm        - Helm CLI"
              echo "  istioctl    - Istio CLI"
              echo ""
              echo "Quick start:"
              echo "  1. k3d-create"
              echo "  2. kubectl apply -f result/manifest.yaml"
              echo ""
            '';
          };

          # Default package builds everything
          default = pkgs.symlinkJoin {
            name = "k3d-istio-all";
            paths = [
              self.packages.${system}.k3d-config
              self.packages.${system}.k3d-scripts
              self.packages.${system}.istio-all
            ];
          };
        }
      );

      # Dev shells
      devShells = forAllSystems (system: {
        default = self.packages.${system}.devShell;
      });

      # Apps for easy execution
      apps = forAllSystems (system: {
        create-cluster = {
          type = "app";
          program = "${self.packages.${system}.k3d-scripts}/bin/k3d-create";
        };
        delete-cluster = {
          type = "app";
          program = "${self.packages.${system}.k3d-scripts}/bin/k3d-delete";
        };
        status = {
          type = "app";
          program = "${self.packages.${system}.k3d-scripts}/bin/k3d-status";
        };
      });
    };
}

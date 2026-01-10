{
  description = "Wookie NixPkgs - Kubernetes deployments with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Create a NixOS-style module evaluation
      mkConfig = system: modules:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              # Add kubelib overlay (placeholder - would need actual implementation)
              (final: prev: {
                kubelib = {
                  downloadHelmChart = { repo, chart, version, chartHash }: 
                    prev.stdenv.mkDerivation {
                      name = "${chart}-${version}";
                      src = prev.fetchurl {
                        url = "${repo}/${chart}-${version}.tgz";
                        hash = chartHash;
                      };
                      installPhase = ''
                        mkdir -p $out
                        cp -r * $out/
                      '';
                    };
                };
              })
            ];
          };
        in
        nixpkgs.lib.evalModules {
          modules = [
            # Import core modules
            ./modules/platform/kubernetes
            # Import all modules passed as arguments
          ] ++ modules ++ [
            # Inject pkgs and lib
            { _module.args = { inherit pkgs; lib = nixpkgs.lib; }; }
          ];
        };

      # Example configuration: Single-cluster Wookie (with Istio) on local k3d
      wookieLocalConfig = system: mkConfig system [
        ./modules/projects/wookie
        ./modules/targets/local-k3d.nix
        {
          targets.local-k3d = {
            enable = true;
            clusterName = "wookie-local";
          };

          projects.wookie = {
            enable = true;
            clusterRole = "standalone";
            
            # Istio configuration (component of wookie)
            istio = {
              enable = true;
              version = "1_24_2";
              profile = "default";
            };
          };
        }
      ];

    in
    {
      # Export packages for each system
      packages = forAllSystems (system:
        let
          config = wookieLocalConfig system;
        in
        {
          # Cluster management scripts
          create-cluster = config.config.build.scripts.create-cluster or (nixpkgs.legacyPackages.${system}.writeText "placeholder" "Not configured");
          delete-cluster = config.config.build.scripts.delete-cluster or (nixpkgs.legacyPackages.${system}.writeText "placeholder" "Not configured");

          # TODO: Add manifest generation packages
          # manifests-crds = ...
          # manifests-operators = ...
          # manifests-services = ...

          default = config.config.build.scripts.create-cluster or (nixpkgs.legacyPackages.${system}.writeText "placeholder" "Not configured");
        }
      );

      # Export apps for easy execution
      apps = forAllSystems (system: {
        create-cluster = {
          type = "app";
          program = "${self.packages.${system}.create-cluster}";
        };

        delete-cluster = {
          type = "app";
          program = "${self.packages.${system}.delete-cluster}";
        };

        default = self.apps.${system}.create-cluster;
      });

      # Export dev shell
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.k3d
              pkgs.kubectl
              pkgs.kubernetes-helm
              pkgs.istioctl
            ];

            shellHook = ''
              echo "Wookie NixPkgs Development Environment"
              echo ""
              echo "Available commands:"
              echo "  nix run .#create-cluster  - Create local k3d cluster"
              echo "  nix run .#delete-cluster  - Delete local k3d cluster"
              echo ""
              echo "Tools available:"
              echo "  - k3d"
              echo "  - kubectl"
              echo "  - helm"
              echo "  - istioctl"
            '';
          };
        }
      );

      # Export the module system for others to use
      nixosModules = {
        platform-kubernetes = import ./modules/platform/kubernetes;
        project-wookie = import ./modules/projects/wookie;
        target-local-k3d = import ./modules/targets/local-k3d.nix;
      };
    };
}

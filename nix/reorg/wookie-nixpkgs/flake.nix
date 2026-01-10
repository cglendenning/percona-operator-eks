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
              # Add kubelib overlay
              (final: prev: 
                let
                  kubelibModule = import ./lib/kubelib.nix {
                    pkgs = final;
                    lib = nixpkgs.lib;
                  };
                  fleetModule = import ./lib/fleet.nix {
                    pkgs = final;
                    lib = nixpkgs.lib;
                    kubelib = kubelibModule;
                  };
                in
                {
                  kubelib = kubelibModule;
                  fleetlib = fleetModule;
                }
              )
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
          # Get the evaluated config
          config = wookieLocalConfig system;
          clusterConfig = config.config;
          
          # Get pkgs with overlays (already has kubelib and fleetlib)
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              (final: prev: 
                let
                  kubelibModule = import ./lib/kubelib.nix {
                    pkgs = final;
                    lib = nixpkgs.lib;
                  };
                  fleetModule = import ./lib/fleet.nix {
                    pkgs = final;
                    lib = nixpkgs.lib;
                    kubelib = kubelibModule;
                  };
                in
                {
                  kubelib = kubelibModule;
                  fleetlib = fleetModule;
                }
              )
            ];
          };
          
          kubelib = pkgs.kubelib;
          fleetlib = pkgs.fleetlib;
          
          # Generate Fleet bundles for all batches
          fleetBundles = fleetlib.generateAllFleetBundles clusterConfig;
          
          # Get cluster context
          clusterContext = clusterConfig.targets.local-k3d.context or "k3d-wookie-local";
          
        in
        {
          # Cluster management scripts
          create-cluster = clusterConfig.build.scripts.create-cluster or (pkgs.writeText "placeholder" "Not configured");
          delete-cluster = clusterConfig.build.scripts.delete-cluster or (pkgs.writeText "placeholder" "Not configured");

          # Fleet bundles (main deployment artifacts)
          fleet-bundles = fleetBundles;
          
          # Individual batch bundles (for debugging)
          fleet-bundle-crds = fleetlib.generateFleetBundle {
            batchName = "crds";
            bundles = clusterConfig.platform.kubernetes.cluster.batches.crds.bundles;
            priority = clusterConfig.platform.kubernetes.cluster.batches.crds.priority;
            autoPrune = clusterConfig.platform.kubernetes.cluster.batches.crds.autoPrune;
          };
          
          fleet-bundle-namespaces = fleetlib.generateFleetBundle {
            batchName = "namespaces";
            bundles = clusterConfig.platform.kubernetes.cluster.batches.namespaces.bundles;
            priority = clusterConfig.platform.kubernetes.cluster.batches.namespaces.priority;
            autoPrune = clusterConfig.platform.kubernetes.cluster.batches.namespaces.autoPrune;
          };
          
          fleet-bundle-operators = fleetlib.generateFleetBundle {
            batchName = "operators";
            bundles = clusterConfig.platform.kubernetes.cluster.batches.operators.bundles;
            priority = clusterConfig.platform.kubernetes.cluster.batches.operators.priority;
            autoPrune = clusterConfig.platform.kubernetes.cluster.batches.operators.autoPrune;
          };
          
          fleet-bundle-services = fleetlib.generateFleetBundle {
            batchName = "services";
            bundles = clusterConfig.platform.kubernetes.cluster.batches.services.bundles;
            priority = clusterConfig.platform.kubernetes.cluster.batches.services.priority;
            autoPrune = clusterConfig.platform.kubernetes.cluster.batches.services.autoPrune;
          };
          
          # Deployment script
          deploy-fleet = fleetlib.generateFleetDeployScript {
            inherit clusterContext;
            bundlesPackage = fleetBundles;
          };
          
          default = fleetBundles;
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
        
        deploy-fleet = {
          type = "app";
          program = "${self.packages.${system}.deploy-fleet}";
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

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
                in
                {
                  kubelib = kubelibModule;
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
              version = "1_28_2";
              profile = "default";
            };
          };
        }
      ];

      # Multi-cluster configuration: Cluster A (Primary)
      clusterAConfig = system: mkConfig system [
        ./modules/projects/wookie
        ./modules/targets/multi-cluster-k3d.nix
        {
          targets.multi-cluster-k3d.enable = true;

          platform.kubernetes.cluster.uniqueIdentifier = "multi-cluster-a";

          projects.wookie = {
            enable = true;
            clusterRole = "primary";
            namespace = "demo";

            # Istio with east-west gateway
            istio = {
              enable = true;
              version = "1_28_2";
              profile = "default";
              
              istiod.values = {
                pilot = {
                  autoscaleEnabled = false;
                };
                global = {
                  meshID = "mesh1";
                  multiCluster = {
                    clusterName = "cluster-a";
                  };
                  network = "network1";
                };
              };

              eastWestGateway = {
                enabled = true;
                values = {
                  autoscaling.enabled = false;
                  replicaCount = 1;
                  service = {
                    type = "LoadBalancer";
                    ports = [
                      {
                        name = "status-port";
                        port = 15021;
                        targetPort = 15021;
                      }
                      {
                        name = "tls";
                        port = 15443;
                        targetPort = 15443;
                      }
                      {
                        name = "tls-istiod";
                        port = 15012;
                        targetPort = 15012;
                      }
                      {
                        name = "tls-webhook";
                        port = 15017;
                        targetPort = 15017;
                      }
                    ];
                  };
                  labels = {
                    istio = "eastwestgateway";
                    app = "istio-eastwestgateway";
                    topology_istio_io_network = "network1";
                  };
                  env = {
                    ISTIO_META_ROUTER_MODE = "sni-dnat";
                    ISTIO_META_REQUESTED_NETWORK_VIEW = "network1";
                  };
                };
              };
            };

            # Demo helloworld app
            demo-helloworld = {
              enable = true;
              namespace = "demo";
              replicas = 3;
            };
          };
        }
      ];

      # Multi-cluster configuration: Cluster B (DR)
      clusterBConfig = system: mkConfig system [
        ./modules/projects/wookie
        ./modules/targets/multi-cluster-k3d.nix
        {
          targets.multi-cluster-k3d.enable = true;

          platform.kubernetes.cluster.uniqueIdentifier = "multi-cluster-b";

          projects.wookie = {
            enable = true;
            clusterRole = "dr";
            namespace = "demo-dr";

            # Istio with east-west gateway
            istio = {
              enable = true;
              version = "1_28_2";
              profile = "default";
              
              istiod.values = {
                pilot = {
                  autoscaleEnabled = false;
                };
                global = {
                  meshID = "mesh1";
                  multiCluster = {
                    clusterName = "cluster-b";
                  };
                  network = "network2";
                };
              };

              eastWestGateway = {
                enabled = true;
                values = {
                  autoscaling.enabled = false;
                  replicaCount = 1;
                  service = {
                    type = "LoadBalancer";
                    ports = [
                      {
                        name = "status-port";
                        port = 15021;
                        targetPort = 15021;
                      }
                      {
                        name = "tls";
                        port = 15443;
                        targetPort = 15443;
                      }
                      {
                        name = "tls-istiod";
                        port = 15012;
                        targetPort = 15012;
                      }
                      {
                        name = "tls-webhook";
                        port = 15017;
                        targetPort = 15017;
                      }
                    ];
                  };
                  labels = {
                    istio = "eastwestgateway";
                    app = "istio-eastwestgateway";
                    topology_istio_io_network = "network2";
                  };
                  env = {
                    ISTIO_META_ROUTER_MODE = "sni-dnat";
                    ISTIO_META_REQUESTED_NETWORK_VIEW = "network2";
                  };
                };
              };
            };

            # No demo app in cluster B by default
            demo-helloworld.enable = false;
          };
        }
      ];

    in
    {
      # Export packages for each system
      packages = forAllSystems (system:
        let
          # Get pkgs with overlays (already has kubelib)
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              (final: prev: 
                let
                  kubelibModule = import ./lib/kubelib.nix {
                    pkgs = final;
                    lib = nixpkgs.lib;
                  };
                in
                {
                  kubelib = kubelibModule;
                }
              )
            ];
          };
          
          kubelib = pkgs.kubelib;

          # Single-cluster config
          config = wookieLocalConfig system;
          clusterConfig = config.config;
          manifests = kubelib.renderAllBundles clusterConfig;
          clusterContext = clusterConfig.targets.local-k3d.context or "k3d-wookie-local";

          # Multi-cluster configs
          configA = clusterAConfig system;
          clusterConfigA = configA.config;
          manifestsA = kubelib.renderAllBundles clusterConfigA;
          clusterContextA = "k3d-cluster-a";

          configB = clusterBConfig system;
          clusterConfigB = configB.config;
          manifestsB = kubelib.renderAllBundles clusterConfigB;
          clusterContextB = "k3d-cluster-b";
          
        in
        {
          # Single-cluster management scripts
          create-cluster = clusterConfig.build.scripts.create-cluster or (pkgs.writeText "placeholder" "Not configured");
          delete-cluster = clusterConfig.build.scripts.delete-cluster or (pkgs.writeText "placeholder" "Not configured");

          # Rendered Kubernetes manifests
          manifests = manifests;
          
          # Deployment script
          deploy = kubelib.generateDeployScript {
            inherit clusterContext clusterConfig;
            manifestsPackage = manifests;
          };

          # Multi-cluster management scripts
          create-clusters = clusterConfigA.build.scripts.create-clusters or (pkgs.writeText "placeholder" "Not configured");
          delete-clusters = clusterConfigA.build.scripts.delete-clusters or (pkgs.writeText "placeholder" "Not configured");
          status-clusters = clusterConfigA.build.scripts.status-clusters or (pkgs.writeText "placeholder" "Not configured");

          # Multi-cluster manifests
          manifests-cluster-a = manifestsA;
          manifests-cluster-b = manifestsB;

          # Individual cluster deployment scripts
          deploy-cluster-a = kubelib.generateDeployScript {
            clusterContext = clusterContextA;
            clusterConfig = clusterConfigA;
            manifestsPackage = manifestsA;
          };

          deploy-cluster-b = kubelib.generateDeployScript {
            clusterContext = clusterContextB;
            clusterConfig = clusterConfigB;
            manifestsPackage = manifestsB;
          };

          # Test script for multi-cluster setup
          test-multi-cluster = pkgs.writeShellApplication {
            name = "test-multi-cluster";
            runtimeInputs = [ pkgs.kubectl pkgs.istioctl pkgs.curl ];
            text = builtins.readFile ./lib/helpers/test-multi-cluster.sh;
          };

          # Multi-cluster deployment script
          deploy-multi-cluster = pkgs.writeShellApplication {
            name = "deploy-multi-cluster";
            runtimeInputs = [ 
              pkgs.kubectl 
              pkgs.istioctl 
              pkgs.docker 
              pkgs.jq 
              pkgs.yq-go 
            ];
            text = ''
              export CLUSTER_A_CONTEXT="${clusterContextA}"
              export CLUSTER_B_CONTEXT="${clusterContextB}"
              export MANIFESTS_CLUSTER_A_PATH="${manifestsA}/manifest.yaml"
              export MANIFESTS_CLUSTER_B_PATH="${manifestsB}/manifest.yaml"
              
              ${builtins.readFile ./lib/helpers/deploy-multi-cluster.sh}
            '';
          };
          
          default = manifests;
        }
      );

      # Export apps for easy execution
      apps = forAllSystems (system: {
        # Single-cluster commands
        create-cluster = {
          type = "app";
          program = "${self.packages.${system}.create-cluster}";
        };

        delete-cluster = {
          type = "app";
          program = "${self.packages.${system}.delete-cluster}";
        };
        
        deploy = {
          type = "app";
          program = "${self.packages.${system}.deploy}";
        };

        # Multi-cluster commands
        create-clusters = {
          type = "app";
          program = "${self.packages.${system}.create-clusters}";
        };

        delete-clusters = {
          type = "app";
          program = "${self.packages.${system}.delete-clusters}";
        };

        status-clusters = {
          type = "app";
          program = "${self.packages.${system}.status-clusters}";
        };

        deploy-cluster-a = {
          type = "app";
          program = "${self.packages.${system}.deploy-cluster-a}";
        };

        deploy-cluster-b = {
          type = "app";
          program = "${self.packages.${system}.deploy-cluster-b}";
        };

        deploy-multi-cluster = {
          type = "app";
          program = "${self.packages.${system}.deploy-multi-cluster}/bin/deploy-multi-cluster";
        };

        test-multi-cluster = {
          type = "app";
          program = "${self.packages.${system}.test-multi-cluster}/bin/test-multi-cluster";
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
              echo "Single-cluster commands:"
              echo "  nix run .#create-cluster  - Create local k3d cluster"
              echo "  nix run .#delete-cluster  - Delete local k3d cluster"
              echo "  nix build .#manifests     - Build Kubernetes manifests"
              echo "  nix run .#deploy          - Deploy to cluster"
              echo ""
              echo "Multi-cluster commands:"
              echo "  nix run .#create-clusters       - Create cluster-a and cluster-b"
              echo "  nix run .#delete-clusters       - Delete both clusters"
              echo "  nix run .#status-clusters       - Show cluster status"
              echo "  nix run .#deploy-multi-cluster  - Deploy to both clusters with remote secrets"
              echo "  nix run .#test-multi-cluster    - Test cross-cluster connectivity"
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

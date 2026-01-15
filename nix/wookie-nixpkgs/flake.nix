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
          
          # Internal scripts (not exposed in packages)
          _internal = {
            create-cluster = clusterConfig.build.scripts.create-cluster;
            delete-cluster = clusterConfig.build.scripts.delete-cluster;
            deploy = clusterConfig.build.scripts.deploy-helmfile;
            create-clusters = clusterConfigA.build.scripts.create-clusters;
            delete-clusters = clusterConfigA.build.scripts.delete-clusters;
            deploy-cluster-a = clusterConfigA.build.scripts.deploy-helmfile;
            deploy-cluster-b = clusterConfigB.build.scripts.deploy-helmfile;
          };
        in
        {
          # Main commands
          up = pkgs.writeShellApplication {
            name = "up";
            runtimeInputs = [ pkgs.k3d pkgs.helmfile pkgs.kubernetes-helm pkgs.kubectl ];
            text = ''
              set -euo pipefail
              
              echo "=== Standing up single cluster stack ==="
              echo ""
              
              echo "Step 1: Creating k3d cluster..."
              ${_internal.create-cluster}
              
              echo ""
              echo "Step 2: Deploying via helmfile..."
              CLUSTER_CONTEXT="${clusterContext}" ${_internal.deploy}/bin/deploy-local-k3d-wookie-local-helmfile
              
              echo ""
              echo "=== Stack is up! ==="
              echo ""
              echo "Verify with:"
              echo "  kubectl get pods -A --context ${clusterContext}"
            '';
          };
          
          down = pkgs.writeShellApplication {
            name = "down";
            runtimeInputs = [ pkgs.k3d ];
            text = ''
              set -euo pipefail
              
              echo "=== Tearing down single cluster stack ==="
              echo ""
              
              ${_internal.delete-cluster}
              
              echo ""
              echo "=== Stack is down! ==="
            '';
          };
          
          up-multi = 
            let
              certScript = clusterConfigA.projects.wookie.istio.helpers.mkCertificateScript;
            in
            pkgs.writeShellApplication {
              name = "up-multi";
              runtimeInputs = [ pkgs.k3d pkgs.helmfile pkgs.kubernetes-helm pkgs.kubectl pkgs.istioctl pkgs.openssl pkgs.docker ];
              text = ''
                set -euo pipefail
                CERTS_DIR="./certs"
                
                echo "=== Standing up multi-cluster stack ==="
                
                # 1. Generate certificates if needed
                if [ ! -f "$CERTS_DIR/root-cert.pem" ]; then
                  echo "Generating certificates..."
                  ${certScript} "$CERTS_DIR"
                else
                  echo "Using existing certificates"
                  openssl x509 -in "$CERTS_DIR/root-cert.pem" -noout -fingerprint -sha256
                fi
                
                # 2. Create clusters
                echo "Creating k3d clusters..."
                ${_internal.create-clusters}
                
                # 3. Install CA certificates
                for CLUSTER in cluster-a cluster-b; do
                  CTX="k3d-$CLUSTER"
                  NET=$([[ "$CLUSTER" == "cluster-a" ]] && echo "network1" || echo "network2")
                  
                  kubectl create namespace istio-system --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
                  kubectl label namespace istio-system topology.istio.io/network=$NET --context="$CTX" --overwrite
                  kubectl create secret generic cacerts -n istio-system \
                    --from-file=ca-cert.pem="$CERTS_DIR/$CLUSTER-ca-cert.pem" \
                    --from-file=ca-key.pem="$CERTS_DIR/$CLUSTER-ca-key.pem" \
                    --from-file=root-cert.pem="$CERTS_DIR/root-cert.pem" \
                    --from-file=cert-chain.pem="$CERTS_DIR/$CLUSTER-cert-chain.pem" \
                    --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
                done
                
                # 4. Deploy Istio and apps
                echo "Deploying cluster-a..."
                CLUSTER_CONTEXT="${clusterContextA}" ${_internal.deploy-cluster-a}/bin/deploy-multi-cluster-a-helmfile
                echo "Deploying cluster-b..."
                CLUSTER_CONTEXT="${clusterContextB}" ${_internal.deploy-cluster-b}/bin/deploy-multi-cluster-b-helmfile
                
                # 5. Configure cross-cluster discovery
                echo "Waiting for istiod..."
                kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${clusterContextA}
                kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${clusterContextB}
                
                API_A=$(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
                API_B=$(docker inspect k3d-cluster-b-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
                
                istioctl create-remote-secret --context=${clusterContextA} --name=cluster-a --server="https://$API_A:6443" | kubectl apply -f - --context=${clusterContextB}
                istioctl create-remote-secret --context=${clusterContextB} --name=cluster-b --server="https://$API_B:6443" | kubectl apply -f - --context=${clusterContextA}
                
                # 6. Configure meshNetworks
                echo "Configuring meshNetworks..."
                kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=${clusterContextA} || true
                kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=${clusterContextB} || true
                
                GW_A=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${clusterContextA} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
                GW_B=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${clusterContextB} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
                
                # Use Nix-generated meshNetworks config generator
                ${clusterConfigA.projects.wookie.istio.helpers.meshNetworksGenerator} "$GW_A" "$GW_B" | kubectl apply -f - --context=${clusterContextA}
                ${clusterConfigB.projects.wookie.istio.helpers.meshNetworksGenerator} "$GW_A" "$GW_B" | kubectl apply -f - --context=${clusterContextB}
                
                # 7. Restart pods to pick up config
                for CTX in ${clusterContextA} ${clusterContextB}; do
                  kubectl rollout restart deployment/istiod -n istio-system --context=$CTX
                  kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=$CTX
                done
                kubectl rollout restart deployment/helloworld-v1 -n demo --context=${clusterContextA} || true
                
                echo ""
                echo "=== Multi-cluster stack is up! ==="
                echo "Test: nix run .#test"
              '';
            };
          
          down-multi = pkgs.writeShellApplication {
            name = "down-multi";
            runtimeInputs = [ pkgs.k3d pkgs.docker ];
            text = ''
              echo "=== Tearing down multi-cluster stack ==="
              ${_internal.delete-clusters}
              echo "=== Multi-cluster stack is down! ==="
            '';
          };

          test = pkgs.writeShellApplication {
            name = "test-multi-cluster";
            runtimeInputs = [ pkgs.kubectl pkgs.istioctl pkgs.curl pkgs.jq ];
            text = builtins.readFile ./lib/helpers/test-multi-cluster.sh;
          };

          # Granular Istio management commands
          wookie-istio-down = pkgs.writeShellApplication {
            name = "wookie-istio-down";
            runtimeInputs = [ pkgs.kubectl ];
            text = ''
              echo "=== Removing Istio components (keeping k3d clusters) ==="
              for CONTEXT in k3d-cluster-a k3d-cluster-b; do
                kubectl delete namespace istio-system --context="$CONTEXT" --ignore-not-found=true
              done
              echo "=== Istio components removed! ==="
              echo "Clusters still running. To remove: nix run .#down-multi"
            '';
          };

          wookie-istio-up =
            let
              certScript = clusterConfigA.projects.wookie.istio.helpers.mkCertificateScript;
              meshGen = clusterConfigA.projects.wookie.istio.helpers.meshNetworksGenerator;
            in
            pkgs.writeShellApplication {
              name = "wookie-istio-up";
              runtimeInputs = [ pkgs.kubectl pkgs.helmfile pkgs.istioctl pkgs.openssl pkgs.docker ];
              text = ''
                set -euo pipefail
                CERTS_DIR="./certs"
                
                echo "=== Deploying Istio components (without helloworld) ==="
                
                # 1. Generate/reuse certificates
                [ ! -f "$CERTS_DIR/root-cert.pem" ] && ${certScript} "$CERTS_DIR" || echo "Using existing certificates"
                
                # 2. Install CA certificates
                for CLUSTER in cluster-a cluster-b; do
                  CTX="k3d-$CLUSTER"
                  NET=$([[ "$CLUSTER" == "cluster-a" ]] && echo "network1" || echo "network2")
                  kubectl create namespace istio-system --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
                  kubectl label namespace istio-system topology.istio.io/network=$NET --context="$CTX" --overwrite
                  kubectl create secret generic cacerts -n istio-system \
                    --from-file=ca-cert.pem="$CERTS_DIR/$CLUSTER-ca-cert.pem" \
                    --from-file=ca-key.pem="$CERTS_DIR/$CLUSTER-ca-key.pem" \
                    --from-file=root-cert.pem="$CERTS_DIR/root-cert.pem" \
                    --from-file=cert-chain.pem="$CERTS_DIR/$CLUSTER-cert-chain.pem" \
                    --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
                done
                
                # 3. Deploy Istio (without helloworld - deployments filter that out)
                CLUSTER_CONTEXT="k3d-cluster-a" ${_internal.deploy-cluster-a}/bin/deploy-multi-cluster-a-helmfile
                CLUSTER_CONTEXT="k3d-cluster-b" ${_internal.deploy-cluster-b}/bin/deploy-multi-cluster-b-helmfile
                
                # 4. Configure cross-cluster
                kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=k3d-cluster-a
                kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=k3d-cluster-b
                
                API_A=$(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
                API_B=$(docker inspect k3d-cluster-b-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
                istioctl create-remote-secret --context=k3d-cluster-a --name=cluster-a --server="https://$API_A:6443" | kubectl apply -f - --context=k3d-cluster-b
                istioctl create-remote-secret --context=k3d-cluster-b --name=cluster-b --server="https://$API_B:6443" | kubectl apply -f - --context=k3d-cluster-a
                
                # 5. Configure meshNetworks
                kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=k3d-cluster-a || true
                kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=k3d-cluster-b || true
                
                GW_A=$(kubectl get svc istio-eastwestgateway -n istio-system --context=k3d-cluster-a -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
                GW_B=$(kubectl get svc istio-eastwestgateway -n istio-system --context=k3d-cluster-b -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
                
                ${meshGen} "$GW_A" "$GW_B" | kubectl apply -f - --context=k3d-cluster-a
                ${meshGen} "$GW_A" "$GW_B" | kubectl apply -f - --context=k3d-cluster-b
                
                # 6. Restart to pick up config
                for CTX in k3d-cluster-a k3d-cluster-b; do
                  kubectl rollout restart deployment/istiod -n istio-system --context=$CTX
                  kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=$CTX
                done
                
                echo ""
                echo "=== Istio is up! ==="
                echo "Deploy helloworld: nix run .#wookie-istio-helloworld"
              '';
            };

          wookie-istio-helloworld = 
            let
              helloworldManifest = "${pkgs.kubelib.renderBundle clusterConfigA.platform.kubernetes.cluster.batches.services.bundles.helloworld}/manifest.yaml";
            in
            pkgs.writeShellApplication {
              name = "wookie-istio-helloworld";
              runtimeInputs = [ pkgs.kubectl ];
              text = ''
                echo "=== Deploying helloworld demo to cluster-a ==="
                kubectl apply -f ${helloworldManifest} --context=k3d-cluster-a
                echo "Waiting for helloworld pods..."
                kubectl wait --for=condition=ready pod -l app=helloworld -n demo --context=k3d-cluster-a --timeout=120s
                echo "=== Helloworld demo is up! ==="
                echo "Test: nix run .#test"
              '';
            };

          # Build outputs
          manifests = manifests;
          helmfile = clusterConfig.build.helmfile;
          manifests-cluster-a = manifestsA;
          manifests-cluster-b = manifestsB;
          helmfile-cluster-a = clusterConfigA.build.helmfile;
          helmfile-cluster-b = clusterConfigB.build.helmfile;
          
          default = manifests;
        }
      );

      # Export apps for easy execution (only the main commands)
      apps = forAllSystems (system: {
        # Single cluster
        up = {
          type = "app";
          program = "${self.packages.${system}.up}/bin/up";
        };
        
        down = {
          type = "app";
          program = "${self.packages.${system}.down}/bin/down";
        };
        
        # Multi-cluster
        up-multi = {
          type = "app";
          program = "${self.packages.${system}.up-multi}/bin/up-multi";
        };
        
        down-multi = {
          type = "app";
          program = "${self.packages.${system}.down-multi}/bin/down-multi";
        };
        
        test = {
          type = "app";
          program = "${self.packages.${system}.test}/bin/test-multi-cluster";
        };
        
        # Granular Istio management
        wookie-istio-down = {
          type = "app";
          program = "${self.packages.${system}.wookie-istio-down}/bin/wookie-istio-down";
        };
        
        wookie-istio-up = {
          type = "app";
          program = "${self.packages.${system}.wookie-istio-up}/bin/wookie-istio-up";
        };
        
        wookie-istio-helloworld = {
          type = "app";
          program = "${self.packages.${system}.wookie-istio-helloworld}/bin/wookie-istio-helloworld";
        };

        default = self.apps.${system}.up;
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
              pkgs.helmfile
              pkgs.istioctl
            ];

            shellHook = ''
              echo "Wookie NixPkgs Development Environment"
              echo ""
              echo "Main commands:"
              echo "  nix run           - Stand up single cluster"
              echo "  nix run .#down    - Tear down single cluster"
              echo "  nix run .#up-multi   - Stand up multi-cluster"
              echo "  nix run .#down-multi - Tear down multi-cluster"
              echo "  nix run .#test       - Test multi-cluster connectivity"
              echo ""
              echo "Build outputs:"
              echo "  nix build .#manifests  - Raw Kubernetes manifests"
              echo "  nix build .#helmfile   - Helmfile configuration"
              echo ""
              echo "Advanced (packages only, use 'nix build .#<name>'):"
              echo "  deploy, diff, destroy, create-cluster, delete-cluster"
              echo "  deploy-cluster-a, deploy-cluster-b, diff-cluster-a, diff-cluster-b"
              echo ""
              echo "Tools: k3d, kubectl, helm, helmfile, istioctl"
            '';
          };
        }
      );

      # Export library functions and test assertions
      lib = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          testAssertions = import ./lib/test-assertions.nix { 
            inherit (nixpkgs) lib; 
            inherit pkgs; 
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

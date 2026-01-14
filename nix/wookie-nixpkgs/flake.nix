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
          
          up-multi = pkgs.writeShellApplication {
            name = "up-multi";
            runtimeInputs = [ pkgs.k3d pkgs.helmfile pkgs.kubernetes-helm pkgs.kubectl pkgs.istioctl pkgs.openssl ];
            text = ''
              set -euo pipefail
              
              CERTS_DIR="''${ISTIO_CERTS_DIR:-./certs}"
              
              echo "=== Standing up multi-cluster stack ==="
              echo ""
              
              echo "Step 1: Checking/generating shared CA certificates..."
              if [ ! -f "$CERTS_DIR/root-cert.pem" ]; then
                echo "Certificates not found, generating..."
                ${pkgs.writeShellScript "gen-certs" (builtins.readFile ./lib/helpers/generate-ca-certs.sh)} "$CERTS_DIR"
              else
                echo "Using existing certificates in $CERTS_DIR"
                echo "Root CA fingerprint:"
                openssl x509 -in "$CERTS_DIR/root-cert.pem" -noout -fingerprint -sha256
              fi
              echo ""
              
              echo "Step 2: Creating k3d clusters..."
              ${_internal.create-clusters}
              
              echo ""
              echo "Step 3: Installing shared CA certificates..."
              
              # Cluster A
              echo "Creating cacerts secret in ${clusterContextA} (istio-system namespace)..."
              kubectl create namespace istio-system --context="${clusterContextA}" --dry-run=client -o yaml | \
                kubectl apply --context="${clusterContextA}" -f -
              
              # Label namespace with network (required for multi-cluster)
              kubectl label namespace istio-system topology.istio.io/network=network1 \
                --context="${clusterContextA}" --overwrite
              
              kubectl create secret generic cacerts -n istio-system \
                --from-file=ca-cert.pem="$CERTS_DIR/cluster-a-ca-cert.pem" \
                --from-file=ca-key.pem="$CERTS_DIR/cluster-a-ca-key.pem" \
                --from-file=root-cert.pem="$CERTS_DIR/root-cert.pem" \
                --from-file=cert-chain.pem="$CERTS_DIR/cluster-a-cert-chain.pem" \
                --context="${clusterContextA}" \
                --dry-run=client -o yaml | \
                kubectl apply --context="${clusterContextA}" -f -
              
              # Cluster B
              echo "Creating cacerts secret in ${clusterContextB} (istio-system namespace)..."
              kubectl create namespace istio-system --context="${clusterContextB}" --dry-run=client -o yaml | \
                kubectl apply --context="${clusterContextB}" -f -
              
              # Label namespace with network (required for multi-cluster)
              kubectl label namespace istio-system topology.istio.io/network=network2 \
                --context="${clusterContextB}" --overwrite
              
              kubectl create secret generic cacerts -n istio-system \
                --from-file=ca-cert.pem="$CERTS_DIR/cluster-b-ca-cert.pem" \
                --from-file=ca-key.pem="$CERTS_DIR/cluster-b-ca-key.pem" \
                --from-file=root-cert.pem="$CERTS_DIR/root-cert.pem" \
                --from-file=cert-chain.pem="$CERTS_DIR/cluster-b-cert-chain.pem" \
                --context="${clusterContextB}" \
                --dry-run=client -o yaml | \
                kubectl apply --context="${clusterContextB}" -f -
              
              echo "Certificates installed in both clusters."
              echo ""
              
              echo "Step 4: Deploying to cluster-a via helmfile..."
              CLUSTER_CONTEXT="${clusterContextA}" ${_internal.deploy-cluster-a}/bin/deploy-multi-cluster-a-helmfile
              
              echo ""
              echo "Step 5: Deploying to cluster-b via helmfile..."
              CLUSTER_CONTEXT="${clusterContextB}" ${_internal.deploy-cluster-b}/bin/deploy-multi-cluster-b-helmfile
              
              echo ""
              echo "Step 6: Configuring cross-cluster service discovery..."
              echo "Waiting for istiod to be ready in both clusters..."
              kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${clusterContextA}
              kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${clusterContextB}
              
              echo "Creating remote secrets for endpoint discovery..."
              
              # Get the internal API server IPs
              API_A=$(docker inspect k3d-cluster-a-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
              API_B=$(docker inspect k3d-cluster-b-server-0 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
              
              echo "API Server IPs:"
              echo "  Cluster A: https://$API_A:6443"
              echo "  Cluster B: https://$API_B:6443"
              
              # Create remote secrets with internal IPs
              istioctl create-remote-secret --context=${clusterContextA} --name=cluster-a --server="https://$API_A:6443" | \
                kubectl apply -f - --context=${clusterContextB}
              istioctl create-remote-secret --context=${clusterContextB} --name=cluster-b --server="https://$API_B:6443" | \
                kubectl apply -f - --context=${clusterContextA}
              echo "Remote secrets configured with internal API server IPs."
              
              echo ""
              echo "Step 7: Configuring meshNetworks..."
              echo "Waiting for east-west gateways to get LoadBalancer IPs..."
              kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s \
                service/istio-eastwestgateway -n istio-system --context=${clusterContextA} || true
              kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s \
                service/istio-eastwestgateway -n istio-system --context=${clusterContextB} || true
              
              # Get gateway IPs
              GW_A=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${clusterContextA} \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
              GW_B=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${clusterContextB} \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
              
              echo "Gateway IPs:"
              echo "  Cluster A: $GW_A"
              echo "  Cluster B: $GW_B"
              
              # Configure meshNetworks in both clusters
              cat <<EOF | kubectl apply --context=${clusterContextA} -f -
              apiVersion: v1
              kind: ConfigMap
              metadata:
                name: istio
                namespace: istio-system
              data:
                mesh: |-
                  defaultConfig:
                    discoveryAddress: istiod.istio-system.svc:15012
                    proxyMetadata:
                      ISTIO_META_DNS_CAPTURE: "true"
                      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
                    tracing:
                      zipkin:
                        address: zipkin.istio-system:9411
                  enablePrometheusMerge: true
                  rootNamespace: istio-system
                  trustDomain: cluster.local
                  meshNetworks:
                    network1:
                      endpoints:
                      - fromRegistry: cluster-a
                      gateways:
                      - address: $GW_A
                        port: 15443
                    network2:
                      endpoints:
                      - fromRegistry: cluster-b
                      gateways:
                      - address: $GW_B
                        port: 15443
              EOF
              
              cat <<EOF | kubectl apply --context=${clusterContextB} -f -
              apiVersion: v1
              kind: ConfigMap
              metadata:
                name: istio
                namespace: istio-system
              data:
                mesh: |-
                  defaultConfig:
                    discoveryAddress: istiod.istio-system.svc:15012
                    proxyMetadata:
                      ISTIO_META_DNS_CAPTURE: "true"
                      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
                    tracing:
                      zipkin:
                        address: zipkin.istio-system:9411
                  enablePrometheusMerge: true
                  rootNamespace: istio-system
                  trustDomain: cluster.local
                  meshNetworks:
                    network1:
                      endpoints:
                      - fromRegistry: cluster-a
                      gateways:
                      - address: $GW_A
                        port: 15443
                    network2:
                      endpoints:
                      - fromRegistry: cluster-b
                      gateways:
                      - address: $GW_B
                        port: 15443
              EOF
              
              echo "Restarting istiod to pick up meshNetworks configuration..."
              kubectl rollout restart deployment/istiod -n istio-system --context=${clusterContextA}
              kubectl rollout restart deployment/istiod -n istio-system --context=${clusterContextB}
              kubectl rollout status deployment/istiod -n istio-system --context=${clusterContextA} --timeout=120s
              kubectl rollout status deployment/istiod -n istio-system --context=${clusterContextB} --timeout=120s
              
              echo "Restarting application pods to pick up updated Envoy configuration..."
              kubectl rollout restart deployment/helloworld-v1 -n demo --context=${clusterContextA} || true
              kubectl rollout status deployment/helloworld-v1 -n demo --context=${clusterContextA} --timeout=120s || true
              
              echo "Restarting east-west gateways to pick up meshNetworks..."
              kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=${clusterContextA}
              kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=${clusterContextB}
              kubectl rollout status deployment/istio-eastwestgateway -n istio-system --context=${clusterContextA} --timeout=120s
              kubectl rollout status deployment/istio-eastwestgateway -n istio-system --context=${clusterContextB} --timeout=120s
              
              echo ""
              echo "Waiting for endpoint synchronization (10 seconds)..."
              sleep 10
              
              echo "meshNetworks and DNS proxy configured, pods restarted."
              
              echo ""
              echo "=== Multi-cluster stack is up! ==="
              echo ""
              echo "Verify with:"
              echo "  kubectl get pods -A --context ${clusterContextA}"
              echo "  kubectl get pods -A --context ${clusterContextB}"
              echo ""
              echo "Verify mTLS certificates:"
              echo "  kubectl get secret cacerts -n istio-system --context ${clusterContextA}"
              echo "  kubectl get secret cacerts -n istio-system --context ${clusterContextB}"
              echo ""
              echo "Test cross-cluster connectivity:"
              echo "  nix run .#test"
            '';
          };
          
          down-multi = pkgs.writeShellApplication {
            name = "down-multi";
            runtimeInputs = [ pkgs.k3d pkgs.docker ];
            text = ''
              set -euo pipefail
              
              echo "=== Tearing down multi-cluster stack ==="
              echo ""
              
              ${_internal.delete-clusters}
              
              echo ""
              echo "=== Multi-cluster stack is down! ==="
            '';
          };

          test = pkgs.writeShellApplication {
            name = "test-multi-cluster";
            runtimeInputs = [ pkgs.kubectl pkgs.istioctl pkgs.curl pkgs.jq ];
            text = builtins.readFile ./lib/helpers/test-multi-cluster.sh;
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

{
  description = "k3d cluster with Istio and other services";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    k3d.url = "path:./modules/k3d";
    helm.url = "path:./modules/helm";
    istio.url = "path:./modules/istio";
    service-entry.url = "path:./modules/service-entry";
  };

  outputs = { self, nixpkgs, k3d, helm, istio, service-entry }:
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
          serviceEntryLib = service-entry.lib { inherit pkgs; };
        in
        {
          # k3d cluster configuration
          k3d-config = k3dLib.mkClusterConfig {
            name = clusterName;
            servers = 1;
            agents = 2;
            ports = [
              { port = "80:80"; nodeFilters = [ "loadbalancer" ]; }
              { port = "443:443"; nodeFilters = [ "loadbalancer" ]; }
            ];
            k3sServerArgs = [
              "--disable=traefik"  # Disable Traefik since we're using Istio
            ];
          };

          # k3d cluster management scripts
          k3d-scripts = k3dLib.mkClusterScript {
            name = clusterName;
            configPath = self.packages.${system}.k3d-config;
          };

          # Istio namespace (single-cluster mode)
          istio-namespace = istioLib.mkNamespace {
            namespace = istioNamespace;
          };

          # Istio base (CRDs)
          istio-base = istioLib.mkIstioBase {
            namespace = istioNamespace;
            values = istioLib.defaultValues.base;
          };

          # Istiod (control plane) - single-cluster mode
          istio-istiod = istioLib.mkIstiod {
            namespace = istioNamespace;
            values = istioLib.defaultValues.istiod;
          };

          # Multi-cluster variants
          istio-namespace-cluster-a = istioLib.mkNamespace {
            namespace = istioNamespace;
            network = "network1";
          };

          istio-istiod-cluster-a = istioLib.mkIstiod {
            namespace = istioNamespace;
            values = istioLib.mkMultiClusterValues {
              clusterId = "cluster-a";
              network = "network1";
              meshId = "mesh1";
            };
          };

          istio-namespace-cluster-b = istioLib.mkNamespace {
            namespace = istioNamespace;
            network = "network2";
          };

          istio-istiod-cluster-b = istioLib.mkIstiod {
            namespace = istioNamespace;
            values = istioLib.mkMultiClusterValues {
              clusterId = "cluster-b";
              network = "network2";
              meshId = "mesh1";
            };
          };

          # East-west gateways
          istio-eastwestgateway-cluster-a = istioLib.mkEastWestGateway {
            namespace = istioNamespace;
            network = "network1";
            nodePort = 30443;
          };

          istio-eastwestgateway-cluster-b = istioLib.mkEastWestGateway {
            namespace = istioNamespace;
            network = "network2";
            nodePort = 30443;
          };

          # Demo applications
          demo-app-cluster-a = istioLib.mkDemoApp {
            namespace = "demo";
          };

          demo-app-cluster-b = istioLib.mkDemoApp {
            namespace = "demo-dr";
            network = "network2";
          };

          # Certificate generation for multi-cluster mTLS
          istio-shared-root-ca = istioLib.mkSharedRootCA {
            rootCAName = "Istio Root CA";
            validityDays = 3650;
          };

          istio-cacerts-cluster-a = istioLib.mkIntermediateCA {
            intermediateName = "cluster-a";
            rootCA = self.packages.${system}.istio-shared-root-ca;
            validityDays = 3650;
          };

          istio-cacerts-cluster-b = istioLib.mkIntermediateCA {
            intermediateName = "cluster-b";
            rootCA = self.packages.${system}.istio-shared-root-ca;
            validityDays = 3650;
          };

          istio-cacerts-secret-cluster-a = istioLib.mkCACertsSecret {
            namespace = "istio-system";
            certs = self.packages.${system}.istio-cacerts-cluster-a;
          };

          istio-cacerts-secret-cluster-b = istioLib.mkCACertsSecret {
            namespace = "istio-system";
            certs = self.packages.${system}.istio-cacerts-cluster-b;
          };

          # Multi-cluster deployment script
          multi-cluster-deploy = pkgs.writeShellApplication {
            name = "multi-cluster-deploy";
            runtimeInputs = [ pkgs.kubectl pkgs.istioctl pkgs.jq pkgs.docker pkgs.yq-go ];
            text = ''
              set -euo pipefail

              CTX_CLUSTER1="k3d-cluster-a"
              CTX_CLUSTER2="k3d-cluster-b"

              echo "=== Deploying Istio Multi-Primary Multi-Network ==="
              echo ""

              # Step 1: Deploy istio-base (CRDs)
              echo "Step 1: Deploying Istio base (CRDs)..."
              kubectl --context="$CTX_CLUSTER1" apply -f ${self.packages.${system}.istio-namespace-cluster-a}/manifest.yaml
              kubectl --context="$CTX_CLUSTER1" apply -f ${self.packages.${system}.istio-base}/manifest.yaml --validate=false
              
              kubectl --context="$CTX_CLUSTER2" apply -f ${self.packages.${system}.istio-namespace-cluster-b}/manifest.yaml
              kubectl --context="$CTX_CLUSTER2" apply -f ${self.packages.${system}.istio-base}/manifest.yaml --validate=false

              # Step 1.5: Deploy CA certificates for mTLS trust
              echo ""
              echo "Step 1.5: Installing CA certificates for cross-cluster mTLS trust..."
              kubectl --context="$CTX_CLUSTER1" apply -f ${self.packages.${system}.istio-cacerts-secret-cluster-a}/manifest.yaml
              kubectl --context="$CTX_CLUSTER2" apply -f ${self.packages.${system}.istio-cacerts-secret-cluster-b}/manifest.yaml
              
              echo "  Shared root CA installed in both clusters"
              echo "  Each cluster has unique intermediate CA signed by shared root"

              # Step 2: Deploy istiod (initial)
              echo ""
              echo "Step 2: Deploying istiod (initial deployment)..."
              kubectl --context="$CTX_CLUSTER1" apply -f ${self.packages.${system}.istio-istiod-cluster-a}/manifest.yaml --validate=false
              kubectl --context="$CTX_CLUSTER2" apply -f ${self.packages.${system}.istio-istiod-cluster-b}/manifest.yaml --validate=false

              echo "  Waiting for istiod..."
              kubectl --context="$CTX_CLUSTER1" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
              kubectl --context="$CTX_CLUSTER2" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

              # Step 3: Deploy east-west gateways
              echo ""
              echo "Step 3: Deploying east-west gateways..."
              kubectl --context="$CTX_CLUSTER1" apply -f ${self.packages.${system}.istio-eastwestgateway-cluster-a}/manifest.yaml
              kubectl --context="$CTX_CLUSTER2" apply -f ${self.packages.${system}.istio-eastwestgateway-cluster-b}/manifest.yaml

              echo "  Waiting for gateways..."
              kubectl --context="$CTX_CLUSTER1" wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system
              kubectl --context="$CTX_CLUSTER2" wait --for=condition=available --timeout=120s deployment/istio-eastwestgateway -n istio-system

              # Step 4: Get gateway IPs and patch services
              echo ""
              echo "Step 4: Configuring gateway external IPs..."

              CLUSTER_A_API_IP=$(docker inspect k3d-cluster-a-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')
              CLUSTER_B_API_IP=$(docker inspect k3d-cluster-b-server-0 | jq -r '.[0].NetworkSettings.Networks["k3d-multicluster"].IPAddress')

              echo "  Cluster A API: $CLUSTER_A_API_IP"
              echo "  Cluster B API: $CLUSTER_B_API_IP"

              CLUSTER_A_NODE_IPS=$(docker network inspect k3d-multicluster | jq -r '.[] | .Containers | to_entries[] | select(.value.Name | startswith("k3d-cluster-a")) | .value.IPv4Address | split("/")[0]' | tr '\n' ',' | sed 's/,$//')
              CLUSTER_B_NODE_IPS=$(docker network inspect k3d-multicluster | jq -r '.[] | .Containers | to_entries[] | select(.value.Name | startswith("k3d-cluster-b")) | .value.IPv4Address | split("/")[0]' | tr '\n' ',' | sed 's/,$//')

              IFS=',' read -ra CLUSTER_A_IPS_ARRAY <<< "$CLUSTER_A_NODE_IPS"
              IFS=',' read -ra CLUSTER_B_IPS_ARRAY <<< "$CLUSTER_B_NODE_IPS"

              CLUSTER_A_EXTERNAL_IPS_JSON=$(printf '%s\n' "''${CLUSTER_A_IPS_ARRAY[@]}" | jq -R . | jq -s .)
              CLUSTER_B_EXTERNAL_IPS_JSON=$(printf '%s\n' "''${CLUSTER_B_IPS_ARRAY[@]}" | jq -R . | jq -s .)

              kubectl --context="$CTX_CLUSTER1" patch service istio-eastwestgateway -n istio-system -p "{\"spec\":{\"externalIPs\":$CLUSTER_A_EXTERNAL_IPS_JSON}}"
              kubectl --context="$CTX_CLUSTER2" patch service istio-eastwestgateway -n istio-system -p "{\"spec\":{\"externalIPs\":$CLUSTER_B_EXTERNAL_IPS_JSON}}"

              GATEWAY_ADDRESS_NETWORK1="''${CLUSTER_A_IPS_ARRAY[0]}"
              GATEWAY_ADDRESS_NETWORK2="''${CLUSTER_B_IPS_ARRAY[0]}"

              echo "  Gateway network1: $GATEWAY_ADDRESS_NETWORK1"
              echo "  Gateway network2: $GATEWAY_ADDRESS_NETWORK2"

              # Step 5: Update istiod with gateway addresses
              echo ""
              echo "Step 5: Updating istiod with gateway addresses..."

              yq eval '
                (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.mesh) |= (
                  . | from_yaml |
                  .meshNetworks.network1.gateways[0] = {"address": "'"$GATEWAY_ADDRESS_NETWORK1"'", "port": 15443} |
                  .meshNetworks.network2.gateways[0] = {"address": "'"$GATEWAY_ADDRESS_NETWORK2"'", "port": 15443} |
                  to_yaml
                ) |
                (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.meshNetworks) = (
                  {"networks": {
                    "network1": {
                      "endpoints": [{"fromRegistry": "cluster-a"}],
                      "gateways": [{"address": "'"$GATEWAY_ADDRESS_NETWORK1"'", "port": 15443}]
                    },
                    "network2": {
                      "endpoints": [{"fromRegistry": "cluster-b"}],
                      "gateways": [{"address": "'"$GATEWAY_ADDRESS_NETWORK2"'", "port": 15443}]
                    }
                  }} | to_yaml
                )
              ' ${self.packages.${system}.istio-istiod-cluster-a}/manifest.yaml > /tmp/istiod-cluster-a-patched.yaml

              yq eval '
                (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.mesh) |= (
                  . | from_yaml |
                  .meshNetworks.network1.gateways[0] = {"address": "'"$GATEWAY_ADDRESS_NETWORK1"'", "port": 15443} |
                  .meshNetworks.network2.gateways[0] = {"address": "'"$GATEWAY_ADDRESS_NETWORK2"'", "port": 15443} |
                  to_yaml
                ) |
                (select(.kind == "ConfigMap" and .metadata.name == "istio") | .data.meshNetworks) = (
                  {"networks": {
                    "network1": {
                      "endpoints": [{"fromRegistry": "cluster-a"}],
                      "gateways": [{"address": "'"$GATEWAY_ADDRESS_NETWORK1"'", "port": 15443}]
                    },
                    "network2": {
                      "endpoints": [{"fromRegistry": "cluster-b"}],
                      "gateways": [{"address": "'"$GATEWAY_ADDRESS_NETWORK2"'", "port": 15443}]
                    }
                  }} | to_yaml
                )
              ' ${self.packages.${system}.istio-istiod-cluster-b}/manifest.yaml > /tmp/istiod-cluster-b-patched.yaml

              kubectl --context="$CTX_CLUSTER1" apply -f /tmp/istiod-cluster-a-patched.yaml --validate=false
              kubectl --context="$CTX_CLUSTER2" apply -f /tmp/istiod-cluster-b-patched.yaml --validate=false

              kubectl --context="$CTX_CLUSTER1" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system
              kubectl --context="$CTX_CLUSTER2" wait --for=condition=available --timeout=120s deployment/istiod -n istio-system

              # Step 6: Create remote secrets
              echo ""
              echo "Step 6: Creating remote secrets for endpoint discovery..."

              istioctl create-remote-secret \
                --context="$CTX_CLUSTER2" \
                --name=cluster-b \
                --server="https://$CLUSTER_B_API_IP:6443" | \
                kubectl apply -f - --context="$CTX_CLUSTER1"

              istioctl create-remote-secret \
                --context="$CTX_CLUSTER1" \
                --name=cluster-a \
                --server="https://$CLUSTER_A_API_IP:6443" | \
                kubectl apply -f - --context="$CTX_CLUSTER2"

              echo "  Waiting for cross-cluster endpoint discovery..."
              sleep 10

              echo "  Restarting istiod pods..."
              kubectl --context="$CTX_CLUSTER1" rollout restart deployment/istiod -n istio-system
              kubectl --context="$CTX_CLUSTER2" rollout restart deployment/istiod -n istio-system

              kubectl --context="$CTX_CLUSTER1" rollout status deployment/istiod -n istio-system --timeout=120s
              kubectl --context="$CTX_CLUSTER2" rollout status deployment/istiod -n istio-system --timeout=120s

              # Step 7: Deploy demo apps
              echo ""
              echo "Step 7: Deploying demo applications..."

              kubectl --context="$CTX_CLUSTER1" apply -f ${self.packages.${system}.demo-app-cluster-a}/manifest.yaml
              kubectl --context="$CTX_CLUSTER2" apply -f ${self.packages.${system}.demo-app-cluster-b}/manifest.yaml

              echo "  Waiting for hello pods..."
              for i in {1..30}; do
                POD_COUNT=$(kubectl --context="$CTX_CLUSTER1" get pods -n demo -l app=hello --no-headers 2>/dev/null | wc -l || echo 0)
                if [ "$POD_COUNT" -gt 0 ]; then
                  break
                fi
                echo "    Waiting for StatefulSet to create pods... ($i/30)"
                sleep 2
              done

              kubectl --context="$CTX_CLUSTER1" wait --for=condition=ready --timeout=300s pod -l app=hello -n demo

              echo ""
              echo "=== Deployment Complete ==="
              echo ""
              echo "Gateway addresses configured:"
              echo "  network1 (cluster-a): $GATEWAY_ADDRESS_NETWORK1:15443"
              echo "  network2 (cluster-b): $GATEWAY_ADDRESS_NETWORK2:15443"
              echo ""
            '';
          };

          # Istio ingress gateway (commented out - k3d doesn't support sysctls)
          # Only needed for HTTP/HTTPS external traffic, not for PXC replication
          # istio-gateway = istioLib.mkIstioGateway {
          #   namespace = istioNamespace;
          #   values = istioLib.defaultValues.gateway;
          # };
          
          # Demo: ServiceEntry for hello service in cluster-a
          # Uses NodePort services and node IPs on shared network
          # Client requests port 8080, ServiceEntry routes to node-IP:NodePort
          hello-remote = pkgs.runCommand "hello-remote-serviceentry" { } ''
            mkdir -p $out
            cat > $out/manifest.yaml << 'EOF'
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: hello-0-external
  namespace: demo
spec:
  hosts:
  - "hello-0.hello.demo.svc.cluster.local"
  addresses:
  - "172.21.0.2"  # k3d-cluster-a-server-0 IP on shared network
  ports:
  - number: 8080
    name: http
    protocol: HTTP
    targetPort: 30080
  location: MESH_INTERNAL
  resolution: STATIC
  endpoints:
  - address: "172.21.0.2"
    ports:
      http: 30080
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: hello-1-external
  namespace: demo
spec:
  hosts:
  - "hello-1.hello.demo.svc.cluster.local"
  addresses:
  - "172.21.0.3"  # k3d-cluster-a-agent-0 IP on shared network
  ports:
  - number: 8080
    name: http
    protocol: HTTP
    targetPort: 30081
  location: MESH_INTERNAL
  resolution: STATIC
  endpoints:
  - address: "172.21.0.3"
    ports:
      http: 30081
---
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: hello-2-external
  namespace: demo
spec:
  hosts:
  - "hello-2.hello.demo.svc.cluster.local"
  addresses:
  - "172.21.0.4"  # k3d-cluster-a-agent-1 IP on shared network
  ports:
  - number: 8080
    name: http
    protocol: HTTP
    targetPort: 30082
  location: MESH_INTERNAL
  resolution: STATIC
  endpoints:
  - address: "172.21.0.4"
    ports:
      http: 30082
EOF
          '';

          # Combined Istio manifests (single-cluster)
          istio-all = pkgs.runCommand "istio-all" { } ''
            mkdir -p $out
            
            echo "# Istio Namespace" > $out/manifest.yaml
            cat ${self.packages.${system}.istio-namespace}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istio Base (CRDs)" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-base}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istiod (Control Plane)" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-istiod}/manifest.yaml >> $out/manifest.yaml
            
            # Create deployment script
            cat > $out/deploy.sh << 'EOF'
            #!/usr/bin/env bash
            set -euo pipefail
            
            SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
            
            echo "Deploying Istio to k3d cluster..."
            echo ""
            
            # Apply without validation for CRDs (k3s doesn't support x-kubernetes-validations)
            echo "Installing Istio components..."
            kubectl apply -f "''${SCRIPT_DIR}/manifest.yaml" --validate=false
            
            echo ""
            echo "Waiting for Istio control plane to be ready..."
            kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system 2>/dev/null || true
            
            echo ""
            echo "Istio deployment complete!"
            echo ""
            echo "Check status:"
            echo "  kubectl get pods -n istio-system"
            echo "  istioctl version"
            EOF
            
            chmod +x $out/deploy.sh
          '';

          # Combined Istio manifests for cluster-a (multi-cluster mode)
          istio-cluster-a = pkgs.runCommand "istio-cluster-a" { } ''
            mkdir -p $out
            
            echo "# Istio Namespace for cluster-a" > $out/manifest.yaml
            cat ${self.packages.${system}.istio-namespace-cluster-a}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istio Base (CRDs)" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-base}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istiod (Control Plane) for cluster-a" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-istiod-cluster-a}/manifest.yaml >> $out/manifest.yaml
          '';

          # Combined Istio manifests for cluster-b (multi-cluster mode)
          istio-cluster-b = pkgs.runCommand "istio-cluster-b" { } ''
            mkdir -p $out
            
            echo "# Istio Namespace for cluster-b" > $out/manifest.yaml
            cat ${self.packages.${system}.istio-namespace-cluster-b}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istio Base (CRDs)" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-base}/manifest.yaml >> $out/manifest.yaml
            
            echo "---" >> $out/manifest.yaml
            echo "# Istiod (Control Plane) for cluster-b" >> $out/manifest.yaml
            echo "---" >> $out/manifest.yaml
            cat ${self.packages.${system}.istio-istiod-cluster-b}/manifest.yaml >> $out/manifest.yaml
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
        deploy = {
          type = "app";
          program = "${self.packages.${system}.multi-cluster-deploy}/bin/multi-cluster-deploy";
        };
        default = {
          type = "app";
          program = "${self.packages.${system}.multi-cluster-deploy}/bin/multi-cluster-deploy";
        };
      });
    };
}

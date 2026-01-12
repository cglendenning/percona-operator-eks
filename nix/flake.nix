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
      });
    };
}

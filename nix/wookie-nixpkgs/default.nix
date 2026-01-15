{ nixpkgs ? <nixpkgs> }:

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

  # Cluster configurations (imported from configs/)
  wookieLocalConfig = system: mkConfig system (import ./configs/local.nix);
  clusterAConfig = system: mkConfig system (import ./configs/cluster-a.nix);
  clusterBConfig = system: mkConfig system (import ./configs/cluster-b.nix);

in
rec {
  # Export configurations for external use
  inherit mkConfig wookieLocalConfig clusterAConfig clusterBConfig;
  
  # Export test assertions for each system
  testAssertions = forAllSystems (system:
    let
      pkgs = import nixpkgs { inherit system; };
    in
    import ./lib/test-assertions.nix { inherit (nixpkgs) lib; inherit pkgs; }
  );
  
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
      
      config = wookieLocalConfig system;
      clusterConfig = config.config;
      manifests = kubelib.renderAllBundles clusterConfig;
      clusterContext = clusterConfig.targets.local-k3d.context or "k3d-wookie-local";

      configA = clusterAConfig system;
      clusterConfigA = configA.config;
      manifestsA = kubelib.renderAllBundles clusterConfigA;

      configB = clusterBConfig system;
      clusterConfigB = configB.config;
      manifestsB = kubelib.renderAllBundles clusterConfigB;
      
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
          k3d = clusterConfigA.build.k3d;
          meshGen = clusterConfigA.projects.wookie.istio.helpers.meshNetworksGenerator;
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
            for CLUSTER in ${k3d.clusterA.name} ${k3d.clusterB.name}; do
              CTX="k3d-$CLUSTER"
              NET=$([[ "$CLUSTER" == "${k3d.clusterA.name}" ]] && echo "network1" || echo "network2")
              
              kubectl create namespace istio-system --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
              kubectl label namespace istio-system "topology.istio.io/network=$NET" --context="$CTX" --overwrite
              kubectl create secret generic cacerts -n istio-system \
                --from-file=ca-cert.pem="$CERTS_DIR/$CLUSTER-ca-cert.pem" \
                --from-file=ca-key.pem="$CERTS_DIR/$CLUSTER-ca-key.pem" \
                --from-file=root-cert.pem="$CERTS_DIR/root-cert.pem" \
                --from-file=cert-chain.pem="$CERTS_DIR/$CLUSTER-cert-chain.pem" \
                --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
            done
            
            # 4. Deploy Istio and apps
            echo "Deploying cluster-a..."
            CLUSTER_CONTEXT="${k3d.clusterA.context}" ${_internal.deploy-cluster-a}/bin/deploy-multi-cluster-a-helmfile
            echo "Deploying cluster-b..."
            CLUSTER_CONTEXT="${k3d.clusterB.context}" ${_internal.deploy-cluster-b}/bin/deploy-multi-cluster-b-helmfile
            
            # 5. Configure cross-cluster discovery
            echo "Waiting for istiod..."
            kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${k3d.clusterA.context}
            kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${k3d.clusterB.context}
            
            # Get k3d API server IPs
            ${k3d.getApiIps}
            
            istioctl create-remote-secret --context=${k3d.clusterA.context} --name=${k3d.clusterA.name} --server="https://$API_A:6443" | kubectl apply -f - --context=${k3d.clusterB.context}
            istioctl create-remote-secret --context=${k3d.clusterB.context} --name=${k3d.clusterB.name} --server="https://$API_B:6443" | kubectl apply -f - --context=${k3d.clusterA.context}
            
            # 6. Configure meshNetworks
            echo "Configuring meshNetworks..."
            kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=${k3d.clusterA.context} || true
            kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=${k3d.clusterB.context} || true
            
            GW_A=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${k3d.clusterA.context} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
            GW_B=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${k3d.clusterB.context} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
            
            # Use Nix-generated meshNetworks config generator
            ${meshGen} "$GW_A" "$GW_B" | kubectl apply -f - --context=${k3d.clusterA.context}
            ${meshGen} "$GW_A" "$GW_B" | kubectl apply -f - --context=${k3d.clusterB.context}
            
            # 7. Restart pods to pick up config
            for CTX in ${k3d.clusterA.context} ${k3d.clusterB.context}; do
              kubectl rollout restart deployment/istiod -n istio-system --context=$CTX
              kubectl rollout restart deployment/istio-eastwestgateway -n istio-system --context=$CTX
            done
            kubectl rollout restart deployment/helloworld-v1 -n demo --context=${k3d.clusterA.context} || true
            
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
      wookie-istio-down = 
        let
          k3d = clusterConfigA.build.k3d;
        in
        pkgs.writeShellApplication {
          name = "wookie-istio-down";
          runtimeInputs = [ pkgs.kubectl ];
          text = ''
            echo "=== Removing Istio components (keeping k3d clusters) ==="
            for CONTEXT in ${k3d.clusterA.context} ${k3d.clusterB.context}; do
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
          k3d = clusterConfigA.build.k3d;
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
            for CLUSTER in ${k3d.clusterA.name} ${k3d.clusterB.name}; do
              CTX="k3d-$CLUSTER"
              NET=$([[ "$CLUSTER" == "${k3d.clusterA.name}" ]] && echo "network1" || echo "network2")
              kubectl create namespace istio-system --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
              kubectl label namespace istio-system "topology.istio.io/network=$NET" --context="$CTX" --overwrite
              kubectl create secret generic cacerts -n istio-system \
                --from-file=ca-cert.pem="$CERTS_DIR/$CLUSTER-ca-cert.pem" \
                --from-file=ca-key.pem="$CERTS_DIR/$CLUSTER-ca-key.pem" \
                --from-file=root-cert.pem="$CERTS_DIR/root-cert.pem" \
                --from-file=cert-chain.pem="$CERTS_DIR/$CLUSTER-cert-chain.pem" \
                --context="$CTX" --dry-run=client -o yaml | kubectl apply --context="$CTX" -f -
            done
            
            # 3. Deploy Istio (without helloworld - deployments filter that out)
            CLUSTER_CONTEXT="${k3d.clusterA.context}" ${_internal.deploy-cluster-a}/bin/deploy-multi-cluster-a-helmfile
            CLUSTER_CONTEXT="${k3d.clusterB.context}" ${_internal.deploy-cluster-b}/bin/deploy-multi-cluster-b-helmfile
            
            # 4. Configure cross-cluster
            kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${k3d.clusterA.context}
            kubectl wait --for=condition=available --timeout=180s deployment/istiod -n istio-system --context=${k3d.clusterB.context}
            
            ${k3d.getApiIps}
            istioctl create-remote-secret --context=${k3d.clusterA.context} --name=${k3d.clusterA.name} --server="https://$API_A:6443" | kubectl apply -f - --context=${k3d.clusterB.context}
            istioctl create-remote-secret --context=${k3d.clusterB.context} --name=${k3d.clusterB.name} --server="https://$API_B:6443" | kubectl apply -f - --context=${k3d.clusterA.context}
            
            # 5. Configure meshNetworks
            kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=${k3d.clusterA.context} || true
            kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' --timeout=60s service/istio-eastwestgateway -n istio-system --context=${k3d.clusterB.context} || true
            
            GW_A=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${k3d.clusterA.context} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
            GW_B=$(kubectl get svc istio-eastwestgateway -n istio-system --context=${k3d.clusterB.context} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
            
            ${meshGen} "$GW_A" "$GW_B" | kubectl apply -f - --context=${k3d.clusterA.context}
            ${meshGen} "$GW_A" "$GW_B" | kubectl apply -f - --context=${k3d.clusterB.context}
            
            # 6. Restart to pick up config
            for CTX in ${k3d.clusterA.context} ${k3d.clusterB.context}; do
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
          k3d = clusterConfigA.build.k3d;
        in
        pkgs.writeShellApplication {
          name = "wookie-istio-helloworld";
          runtimeInputs = [ pkgs.kubectl ];
          text = ''
            echo "=== Deploying helloworld demo to cluster-a ==="
            kubectl apply -f ${helloworldManifest} --context=${k3d.clusterA.context}
            echo "Waiting for helloworld pods..."
            kubectl wait --for=condition=ready pod -l app=helloworld -n demo --context=${k3d.clusterA.context} --timeout=120s
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
  apps = forAllSystems (system:
    let
      self = packages.${system};
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # Single cluster
      up = {
        type = "app";
        program = "${pkgs.lib.getExe self.up}";
      };
      
      down = {
        type = "app";
        program = "${pkgs.lib.getExe self.down}";
      };
      
      # Multi-cluster
      up-multi = {
        type = "app";
        program = "${pkgs.lib.getExe self.up-multi}";
      };
      
      down-multi = {
        type = "app";
        program = "${pkgs.lib.getExe self.down-multi}";
      };
      
      test = {
        type = "app";
        program = "${pkgs.lib.getExe self.test}";
      };
      
      # Granular Istio management
      wookie-istio-down = {
        type = "app";
        program = "${pkgs.lib.getExe self.wookie-istio-down}";
      };
      
      wookie-istio-up = {
        type = "app";
        program = "${pkgs.lib.getExe self.wookie-istio-up}";
      };
      
      wookie-istio-helloworld = {
        type = "app";
        program = "${pkgs.lib.getExe self.wookie-istio-helloworld}";
      };

      default = apps.${system}.up;
    }
  );

  # Export dev shell
  devShells = forAllSystems (system:
    let
      pkgs = import nixpkgs { inherit system; };
    in
    {
      default = pkgs.mkShell {
        buildInputs = [
          pkgs.k3d
          pkgs.kubectl
          pkgs.kubernetes-helm
          pkgs.helmfile
          pkgs.istioctl
          pkgs.docker
          pkgs.jq
          pkgs.openssl
        ];
        
        shellHook = ''
          echo "Wookie NixPkgs Development Shell"
          echo ""
          echo "Available commands:"
          echo "  nix run .#up          - Stand up single-cluster stack"
          echo "  nix run .#down        - Tear down single-cluster stack"
          echo "  nix run .#up-multi    - Stand up multi-cluster stack"
          echo "  nix run .#down-multi  - Tear down multi-cluster stack"
          echo "  nix run .#test        - Run multi-cluster tests"
          echo ""
          echo "Direct tools: k3d, kubectl, helm, helmfile, istioctl"
        '';
      };
    }
  );

  # Export NixOS modules
  nixosModules = {
    platform-kubernetes = import ./modules/platform/kubernetes;
    project-wookie = import ./modules/projects/wookie;
    target-local-k3d = import ./modules/targets/local-k3d.nix;
  };
}

{
  description = "Fleet configuration generator for k3d cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Fleet configuration for Istio deployment
      generateFleetConfig = { pkgs, istioManifestPath }:
        let
          yaml = pkgs.formats.yaml { };
          
          # Fleet bundle for Istio base (CRDs)
          istioBaseBundle = {
            apiVersion = "fleet.cattle.io/v1alpha1";
            kind = "Bundle";
            metadata = {
              name = "istio-base";
              namespace = "fleet-local";
            };
            spec = {
              targets = [
                { clusterSelector = { }; }
              ];
              resources = [
                {
                  name = "istio-base";
                  content = builtins.readFile "${istioManifestPath}/istio-base/manifest.yaml";
                }
              ];
            };
          };

          # Fleet bundle for Istiod
          istiodBundle = {
            apiVersion = "fleet.cattle.io/v1alpha1";
            kind = "Bundle";
            metadata = {
              name = "istio-istiod";
              namespace = "fleet-local";
            };
            spec = {
              dependsOn = [
                { name = "istio-base"; }
              ];
              targets = [
                { clusterSelector = { }; }
              ];
              resources = [
                {
                  name = "istiod";
                  content = builtins.readFile "${istioManifestPath}/istio-istiod/manifest.yaml";
                }
              ];
            };
          };

          # Fleet bundle for Istio gateway
          gatewayBundle = {
            apiVersion = "fleet.cattle.io/v1alpha1";
            kind = "Bundle";
            metadata = {
              name = "istio-gateway";
              namespace = "fleet-local";
            };
            spec = {
              dependsOn = [
                { name = "istio-istiod"; }
              ];
              targets = [
                { clusterSelector = { }; }
              ];
              resources = [
                {
                  name = "gateway";
                  content = builtins.readFile "${istioManifestPath}/istio-gateway/manifest.yaml";
                }
              ];
            };
          };

        in
        pkgs.runCommand "fleet-config" { } ''
          mkdir -p $out
          
          # Generate fleet.yaml with all bundles
          cat > $out/fleet.yaml << 'EOF'
          # Fleet Configuration for Istio on k3d
          #
          # This configuration deploys Istio components in the correct order:
          # 1. istio-base (CRDs and cluster roles)
          # 2. istio-istiod (control plane)
          # 3. istio-gateway (ingress gateway)
          #
          # Deploy with: kubectl apply -f fleet.yaml
          
          EOF
          
          cat ${yaml.generate "istio-base-bundle.yaml" istioBaseBundle} >> $out/fleet.yaml
          echo "---" >> $out/fleet.yaml
          cat ${yaml.generate "istiod-bundle.yaml" istiodBundle} >> $out/fleet.yaml
          echo "---" >> $out/fleet.yaml
          cat ${yaml.generate "gateway-bundle.yaml" gatewayBundle} >> $out/fleet.yaml
          
          # Generate deployment script
          cat > $out/deploy-fleet.sh << 'SCRIPT'
          #!/usr/bin/env bash
          set -euo pipefail
          
          echo "Deploying Istio via Fleet..."
          
          # Install Fleet if not already installed
          if ! kubectl get namespace fleet-system &>/dev/null; then
            echo "Installing Fleet..."
            helm repo add fleet https://rancher.github.io/fleet-helm-charts/
            helm repo update
            helm install fleet fleet/fleet --namespace fleet-system --create-namespace --wait
            echo "Fleet installed"
          fi
          
          # Apply Fleet bundles
          kubectl apply -f fleet.yaml
          
          echo "Fleet bundles applied. Istio deployment in progress..."
          echo "Monitor with: kubectl get bundles -n fleet-local"
          SCRIPT
          
          chmod +x $out/deploy-fleet.sh
          
          # Generate status check script
          cat > $out/check-status.sh << 'SCRIPT'
          #!/usr/bin/env bash
          set -euo pipefail
          
          echo "=== Fleet Bundles ==="
          kubectl get bundles -n fleet-local
          
          echo ""
          echo "=== Istio Pods ==="
          kubectl get pods -n istio-system
          
          echo ""
          echo "=== Istio Services ==="
          kubectl get svc -n istio-system
          SCRIPT
          
          chmod +x $out/check-status.sh
        '';
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Note: This expects the main flake to be built first
          # Usage: nix build .#istio-all && nix build -f fleet.nix
          default = generateFleetConfig {
            inherit pkgs;
            istioManifestPath = "../result";
          };
        }
      );
    };
}

{ pkgs, lib, kubelib }:

rec {
  # Generate a Fleet Bundle from a batch of bundles
  generateFleetBundle = { batchName, bundles, priority ? 1 }:
    let
      # Filter enabled bundles and sort by dependencies
      enabledBundles = lib.filter (b: b.enabled or true) (lib.attrValues bundles);
      
      # Render each bundle to manifest
      resources = map (bundle: {
        name = bundle.name;
        content = builtins.readFile "${kubelib.renderBundle bundle}/manifest.yaml";
      }) enabledBundles;
      
      # Build Fleet Bundle spec
      bundleSpec = {
        apiVersion = "fleet.cattle.io/v1alpha1";
        kind = "Bundle";
        metadata = {
          name = batchName;
          namespace = "fleet-local";
          labels = {
            "wookie.io/batch" = batchName;
            "wookie.io/priority" = toString priority;
          };
        };
        spec = {
          targets = [{
            clusterSelector = {};
          }];
          
          # Actual Kubernetes resources
          resources = resources;
          
          # Don't add tracking annotations for large resources
          keepResources = true;
          
          # Dependencies (for batch ordering)
          dependsOn = 
            let
              prevBatch = 
                if priority == 300 then "crds"
                else if priority == 600 then "namespaces"
                else if priority == 700 then "operators"
                else null;
            in
            lib.optionals (prevBatch != null) [{
              selector = {
                matchLabels = {
                  "wookie.io/batch" = prevBatch;
                };
              };
            }];
        };
      };
    in
    pkgs.writeText "${batchName}-bundle.yaml" (
      builtins.toJSON bundleSpec
    );

  # Generate all Fleet bundles from cluster configuration
  generateAllFleetBundles = clusterConfig:
    let
      batches = clusterConfig.platform.kubernetes.cluster.batches;
      
      mkBundleForBatch = batchName: batch:
        generateFleetBundle {
          inherit batchName;
          bundles = batch.bundles;
          priority = batch.priority;
        };
      
      bundleFiles = lib.mapAttrs mkBundleForBatch batches;
    in
    pkgs.runCommand "fleet-bundles" {} ''
      mkdir -p $out
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: file: ''
        cp ${file} $out/${name}.yaml
      '') bundleFiles)}
    '';

  # Generate GitRepo resource for Fleet
  generateFleetGitRepo = { name, repo, branch ? "main", paths ? ["fleet"] }:
    pkgs.writeText "fleet-gitrepo.yaml" (builtins.toJSON {
      apiVersion = "fleet.cattle.io/v1alpha1";
      kind = "GitRepo";
      metadata = {
        name = name;
        namespace = "fleet-local";
      };
      spec = {
        inherit repo branch paths;
        targets = [{
          clusterSelector = {};
        }];
      };
    });

  # Generate a deployment script for Fleet
  generateFleetDeployScript = { clusterContext, bundlesPackage }:
    pkgs.writeShellScript "deploy-fleet" ''
      set -euo pipefail
      
      CONTEXT="${clusterContext}"
      BUNDLES_DIR="${bundlesPackage}"
      
      echo "=== Deploying Wookie via Fleet ==="
      echo ""
      echo "Target cluster: $CONTEXT"
      echo ""
      
      # Check if Fleet is installed
      if ! kubectl get crd bundles.fleet.cattle.io --context "$CONTEXT" &>/dev/null; then
        echo "ERROR: Fleet CRDs not found. Install Fleet first:"
        echo "  helm repo add fleet https://rancher.github.io/fleet-helm-charts/"
        echo "  helm repo update"
        echo "  helm -n cattle-fleet-system install --create-namespace --wait fleet-crd fleet/fleet-crd"
        echo "  helm -n cattle-fleet-system install --create-namespace --wait fleet fleet/fleet"
        exit 1
      fi
      
      echo "Fleet detected. Applying bundles..."
      echo ""
      
      # Apply all bundles at once (kubectl can apply a directory)
      echo "Applying all Fleet bundles..."
      kubectl apply -f "$BUNDLES_DIR" --context "$CONTEXT"
      echo ""
      
      echo "=== Fleet bundles applied ==="
      echo ""
      echo "Monitor deployment status:"
      echo "  kubectl get bundles -n fleet-local --context $CONTEXT"
      echo ""
      echo "Check bundle details:"
      echo "  kubectl get bundledeployments -A --context $CONTEXT"
    '';
}

{ pkgs, lib, kubelib }:

rec {
  # Generate a Fleet Bundle from a single Kubernetes bundle
  # Returns a Bundle resource for one bundle (not a batch)
  generateFleetBundleForResource = { bundleName, bundle, batchName, priority ? 1 }:
    let
      # Render the bundle to manifest
      manifestContent = builtins.readFile "${kubelib.renderBundle bundle}/manifest.yaml";
      
      # Build Fleet Bundle spec
      bundleSpec = {
        apiVersion = "fleet.cattle.io/v1alpha1";
        kind = "Bundle";
        metadata = {
          name = bundleName;
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
          
          # Single resource
          resources = [{
            name = bundleName;
            content = manifestContent;
          }];
          
          # Resource management
          correctDrift = {
            enabled = true;
          };
          
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
    pkgs.writeText "${bundleName}-bundle.yaml" (
      builtins.toJSON bundleSpec
    );

  # Generate Fleet Bundles for a batch of bundles (one Bundle per resource)
  generateFleetBundlesForBatch = { batchName, bundles, priority ? 1 }:
    let
      # Filter enabled bundles
      enabledBundles = lib.filter (b: b.enabled or true) (lib.attrValues bundles);
      
      # Generate one Fleet Bundle per resource
      mkBundleForResource = bundle:
        generateFleetBundleForResource {
          bundleName = "${batchName}-${bundle.name}";
          inherit bundle batchName priority;
        };
      
    in
    map mkBundleForResource enabledBundles;

  # Generate all Fleet bundles from cluster configuration
  generateAllFleetBundles = clusterConfig:
    let
      batches = clusterConfig.platform.kubernetes.cluster.batches;
      
      # Generate bundles for each batch (returns list of bundle files)
      mkBundlesForBatch = batchName: batch:
        generateFleetBundlesForBatch {
          inherit batchName;
          bundles = batch.bundles;
          priority = batch.priority;
        };
      
      # Get all bundle files (flattened list)
      allBundleFiles = lib.flatten (lib.mapAttrsToList mkBundlesForBatch batches);
      
    in
    pkgs.runCommand "fleet-bundles" {} ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n" (file: ''
        cp ${file} $out/$(basename ${file})
      '') allBundleFiles}
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

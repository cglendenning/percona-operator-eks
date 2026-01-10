{ pkgs, lib, kubelib }:

rec {
  # Generate a Fleet Bundle from a batch of bundles
  generateFleetBundle = { batchName, bundles, priority ? 1, autoPrune ? true, deleteNamespace ? false }:
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
          
          # Fleet configuration
          helm = {
            releaseName = batchName;
            takeOwnership = false;
          };
          
          # Resource management
          correctDrift = {
            enabled = true;
            force = false;
            keepFailHistory = true;
          };
          
          deleteNamespaceOnRemove = deleteNamespace;
          
          # Actual Kubernetes resources
          resources = resources;
          
          # Dependencies (for batch ordering)
          dependsOn = lib.optionals (priority > 100) [{
            selector = {
              matchLabels = {
                "wookie.io/batch" = 
                  if priority == 200 then "crds"
                  else if priority == 300 then "namespaces"
                  else if priority == 600 then "operators"
                  else null;
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
          autoPrune = batch.autoPrune;
          deleteNamespace = batch.deleteNamespace or false;
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
        echo "  kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet-crd.yaml"
        echo "  kubectl apply -f https://github.com/rancher/fleet/releases/latest/download/fleet.yaml"
        exit 1
      fi
      
      echo "Fleet detected. Applying bundles..."
      echo ""
      
      # Apply bundles in order
      for bundle in crds namespaces operators services; do
        BUNDLE_FILE="$BUNDLES_DIR/$bundle.yaml"
        if [ -f "$BUNDLE_FILE" ]; then
          echo "Applying $bundle bundle..."
          kubectl apply -f "$BUNDLE_FILE" --context "$CONTEXT"
          echo ""
        fi
      done
      
      echo "=== Fleet bundles applied ===" echo ""
      echo "Monitor deployment status:"
      echo "  kubectl get bundles -n fleet-local --context $CONTEXT"
      echo ""
      echo "Check bundle details:"
      echo "  kubectl get bundledeployments -A --context $CONTEXT"
    '';
}

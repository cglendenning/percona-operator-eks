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

  # Generate Fleet manifests (raw Kubernetes manifests organized by batch)
  generateFleetManifests = clusterConfig:
    let
      batches = clusterConfig.platform.kubernetes.cluster.batches;
      
    in
    pkgs.runCommand "fleet-manifests" {} ''
      mkdir -p $out
      
      # Copy manifests organized by batch directory
      # Each directory becomes a separate Fleet bundle
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (batchName: batch:
        let
          enabledBundles = lib.filter (b: b.enabled or true) (lib.attrValues batch.bundles);
        in
        ''
          mkdir -p $out/${batchName}
          ${lib.concatMapStringsSep "\n" (bundle: ''
            cp ${kubelib.renderBundle bundle}/manifest.yaml $out/${batchName}/${bundle.name}.yaml
          '') enabledBundles}
        ''
      ) batches)}
    '';

  # Generate a deployment script for Fleet using GitRepo
  generateFleetDeployScript = { clusterContext, clusterConfig }:
    let
      fleetManifests = generateFleetManifests clusterConfig;
      
    in
    pkgs.writeShellScript "deploy-fleet" ''
      set -euo pipefail
      
      CONTEXT="${clusterContext}"
      MANIFESTS_DIR="${fleetManifests}"
      
      echo "=== Deploying Wookie via Fleet (GitRepo) ==="
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
      
      # Clean up old GitRepo if it exists
      if kubectl get gitrepo wookie-local -n fleet-local --context "$CONTEXT" &>/dev/null; then
        echo "Removing existing GitRepo..."
        kubectl delete gitrepo wookie-local -n fleet-local --context "$CONTEXT"
        sleep 5
        echo ""
      fi
      
      # Create temporary Git repo
      TEMP_REPO=$(mktemp -d)
      echo "Creating temporary Git repository at: $TEMP_REPO"
      echo ""
      
      # Copy manifests to temp repo
      cp -r "$MANIFESTS_DIR"/* "$TEMP_REPO/"
      
      # Initialize Git repo
      cd "$TEMP_REPO"
      git init -q
      git config user.email "fleet@wookie.local"
      git config user.name "Fleet Deployer"
      git add .
      git commit -q -m "Wookie deployment manifests"
      
      echo "Git repository created and committed"
      echo ""
      
      # Create Fleet GitRepo resource
      echo "Creating Fleet GitRepo resource..."
      kubectl apply --context "$CONTEXT" -f - <<EOF
      apiVersion: fleet.cattle.io/v1alpha1
      kind: GitRepo
      metadata:
        name: wookie-local
        namespace: fleet-local
      spec:
        repo: file://$TEMP_REPO
        branch: master
        paths:
        - .
        targets:
        - clusterSelector: {}
      EOF
      
      echo ""
      echo "=== Deployment initiated ==="
      echo ""
      echo "Fleet will now pull and deploy manifests from: file://$TEMP_REPO"
      echo ""
      echo "Monitor deployment status:"
      echo "  kubectl get gitrepos -n fleet-local --context $CONTEXT"
      echo "  kubectl get bundles -n fleet-local --context $CONTEXT"
      echo "  kubectl get bundledeployments -A --context $CONTEXT"
      echo ""
      echo "Note: The temporary Git repo will remain at: $TEMP_REPO"
      echo "      Delete it manually when done: rm -rf $TEMP_REPO"
    '';
}

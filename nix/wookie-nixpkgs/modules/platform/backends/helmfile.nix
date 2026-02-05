# Helmfile backend for Kubernetes platform
# Generates helmfile.yaml for declarative Helm chart deployment
{
  pkgs,
  lib,
  config,
  ...
}:
with lib;

let
  cfg = config.platform.kubernetes;
  yaml = pkgs.formats.yaml { };
  
  # Skip namespace and CRD batches - they're created via kubectl, not helm
  # This avoids validation issues with k8s version mismatches
  shouldSkipBatch = batchName: batchName == "namespaces" || batchName == "crds";
  
  # Resolve a bundle dependency to its full release name across all batches
  # Returns null if the dependency is in a skipped batch
  # Returns namespace/releaseName format for cross-namespace dependencies
  resolveBundleDependency = currentNamespace: depName:
    let
      batches = config.platform.kubernetes.cluster.batches;
      # Search all batches for a bundle with this name
      findInBatch = batchName: batchConfig:
        if builtins.hasAttr depName batchConfig.bundles
        then { 
          inherit batchName; 
          releaseName = "${cfg.cluster.uniqueIdentifier}-${batchName}-${depName}";
          namespace = batchConfig.bundles.${depName}.namespace;
        }
        else null;
      
      # Try each batch
      results = lib.mapAttrsToList findInBatch batches;
      validResults = lib.filter (r: r != null) results;
      result = if (builtins.length validResults) > 0 then builtins.head validResults else null;
    in
    # Return null if dependency is in a skipped batch
    if result == null then null
    else if shouldSkipBatch result.batchName then null
    # If dependency is in a different namespace, use namespace/releaseName format
    else if result.namespace != currentNamespace then "${result.namespace}/${result.releaseName}"
    else result.releaseName;
  
  # Generate a helmfile release for a bundle
  generateRelease = batchName: batchConfig: bundleName: bundle:
    let
      releaseName = "${cfg.cluster.uniqueIdentifier}-${batchName}-${bundleName}";
      # Resolve dependencies and filter out null values (skipped batches)
      resolvedDeps = lib.filter (d: d != null) (map (resolveBundleDependency bundle.namespace) bundle.dependsOn);
      
      # For Helm charts, reference the chart directly
      chartRelease = if bundle.chart != null then {
        name = releaseName;
        namespace = bundle.namespace;
        chart = "${bundle.chart.package}";
        values = [ bundle.chart.values ];
        needs = resolvedDeps;
        # Note: kubeContext is set by helmfile command-line, not in config
      } else null;
      
      # For raw manifests, convert to a proper Helm chart structure
      manifestRelease = if (builtins.length bundle.manifests) > 0 then
        let
          # Create a proper Helm chart with Chart.yaml and templates
          helmChart = pkgs.runCommand "helm-chart-${bundleName}" {} ''
            mkdir -p $out/templates
            
            # Combine all manifests into templates
            # Handle both directory structures and plain files
            ${lib.concatMapStringsSep "\n" (m: ''
              if [ -d ${m} ]; then
                cat ${m}/manifest.yaml >> $out/templates/manifests.yaml
              else
                cat ${m} >> $out/templates/manifests.yaml
              fi
            '') bundle.manifests}
            
            # Generate Chart.yaml in YAML format
            cat > $out/Chart.yaml << 'CHARTEOF'
            apiVersion: v2
            name: ${bundleName}
            version: 0.1.0
            description: Kubernetes manifests for ${bundleName}
            CHARTEOF
          '';
        in
        {
          name = releaseName;
          namespace = bundle.namespace;
          chart = "${helmChart}";
          values = [ {} ];
          needs = resolvedDeps;
          # Note: kubeContext is set by helmfile command-line, not in config
        }
      else null;
      
    in
    if chartRelease != null then chartRelease
    else if manifestRelease != null then manifestRelease
    else null;
  
  # Generate all releases for a batch
  generateBatchReleases = batchName: batchConfig:
    let
      # Get enabled bundles
      enabledBundles = lib.filterAttrs (name: bundle: bundle.enabled or true) batchConfig.bundles;
      
      # Generate releases
      releases = lib.mapAttrsToList (bundleName: bundle:
        generateRelease batchName batchConfig bundleName bundle
      ) enabledBundles;
      
      # Filter out nulls
      validReleases = lib.filter (r: r != null) releases;
      
      # Add batch dependencies to ALL releases in batch (not just first)
      # Filter out dependencies on skipped batches (namespaces, crds)
      releasesWithBatchDeps = map (release:
        let
          filteredBatchDeps = lib.filter (dep: !(shouldSkipBatch dep)) batchConfig.dependsOn;
          batchDeps = map (dep: "${cfg.cluster.uniqueIdentifier}-${dep}-*") filteredBatchDeps;
        in
        release // {
          needs = (release.needs or []) ++ batchDeps;
        }
      ) validReleases;
      
    in
    releasesWithBatchDeps;
  
  # Generate helmfile.yaml
  generateHelmfile = clusterConfig:
    let
      batches = clusterConfig.platform.kubernetes.cluster.batches;
      
      # Sort batches by priority
      sortedBatches = lib.sort 
        (a: b: batches.${a}.priority < batches.${b}.priority)
        (lib.attrNames batches);
      
      # Generate all releases (skip namespaces batch)
      allReleases = lib.flatten (map (batchName:
        if shouldSkipBatch batchName
        then []
        else generateBatchReleases batchName batches.${batchName}
      ) sortedBatches);
      
      helmfileConfig = {
        repositories = [];
        releases = allReleases;
      };
      
    in
    yaml.generate "helmfile.yaml" helmfileConfig;

in
{
  options.platform.kubernetes.backend.helmfile = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Helmfile backend for Kubernetes deployments";
    };
    
    binary = mkOption {
      type = types.package;
      default = pkgs.helmfile;
      description = "Helmfile binary to use";
    };
  };

  config = mkIf cfg.backend.helmfile.enable {
    # Add helmfile generation to build outputs
    build = {
      # Generate helmfile.yaml
      helmfile = generateHelmfile config;
      
      # Generate deployment script
      scripts.deploy-helmfile = pkgs.writeShellApplication {
        name = "deploy-${cfg.cluster.uniqueIdentifier}-helmfile";
        runtimeInputs = [ pkgs.helmfile pkgs.kubernetes-helm pkgs.kubectl ];
        text = ''
          set -euo pipefail
          
          CONTEXT="''${CLUSTER_CONTEXT:-${cfg.cluster.uniqueIdentifier}}"
          HELMFILE="${config.build.helmfile}"
          
          echo "=== Deploying ${cfg.cluster.uniqueIdentifier} via Helmfile ==="
          echo ""
          echo "Context: $CONTEXT"
          echo "Helmfile: $HELMFILE"
          echo ""
          
          # Set kubeconfig context
          export KUBECONFIG=''${KUBECONFIG:-$HOME/.kube/config}
          kubectl config use-context "$CONTEXT" || {
            echo "Error: Context '$CONTEXT' not found"
            exit 1
          }
          
          # First, create namespaces (idempotent - kubectl apply handles this)
          echo "Creating namespaces..."
          ${let
            namespaceBatch = config.platform.kubernetes.cluster.batches.namespaces;
            enabledBundles = lib.filter (b: b.enabled or true) (lib.attrValues namespaceBatch.bundles);
            renderedBundles = map pkgs.kubelib.renderBundle enabledBundles;
          in
          lib.concatMapStringsSep "\n" (ns: ''
            kubectl apply --context "$CONTEXT" -f ${ns}/manifest.yaml
          '') renderedBundles}
          echo ""
          
          # Apply CRDs (use create with --validate=false for k3s compatibility)
          echo "Installing CRDs..."
          ${let
            crdBatch = config.platform.kubernetes.cluster.batches.crds;
            enabledBundles = lib.filter (b: b.enabled or true) (lib.attrValues crdBatch.bundles);
            renderedBundles = map pkgs.kubelib.renderBundle enabledBundles;
          in
          lib.concatMapStringsSep "\n" (crd: ''
            # Use create with --validate=false to bypass x-kubernetes-validations issues
            # Ignore "already exists" errors to make this idempotent
            kubectl create --validate=false --context "$CONTEXT" -f ${crd}/manifest.yaml 2>&1 | grep -v "already exists" || true
          '') renderedBundles}
          echo ""
          
          # Apply helmfile (operators, services)
          echo "Deploying via helmfile..."
          helmfile -f "$HELMFILE" sync \
            --kube-context "$CONTEXT" \
            --concurrency 1
          
          echo ""
          echo "=== Helmfile deployment complete ==="
        '';
      };
      
      # Generate diff script
      scripts.diff-helmfile = pkgs.writeShellApplication {
        name = "diff-${cfg.cluster.uniqueIdentifier}-helmfile";
        runtimeInputs = [ pkgs.helmfile pkgs.kubernetes-helm pkgs.kubectl ];
        text = ''
          set -euo pipefail
          
          CONTEXT="''${CLUSTER_CONTEXT:-${cfg.cluster.uniqueIdentifier}}"
          HELMFILE="${config.build.helmfile}"
          
          echo "=== Diffing ${cfg.cluster.uniqueIdentifier} via Helmfile ==="
          echo ""
          
          helmfile -f "$HELMFILE" diff \
            --kube-context "$CONTEXT" \
            --concurrency 1
        '';
      };
      
      # Generate destroy script
      scripts.destroy-helmfile = pkgs.writeShellApplication {
        name = "destroy-${cfg.cluster.uniqueIdentifier}-helmfile";
        runtimeInputs = [ pkgs.helmfile pkgs.kubernetes-helm pkgs.kubectl ];
        text = ''
          set -euo pipefail
          
          CONTEXT="''${CLUSTER_CONTEXT:-${cfg.cluster.uniqueIdentifier}}"
          HELMFILE="${config.build.helmfile}"
          
          echo "=== Destroying ${cfg.cluster.uniqueIdentifier} via Helmfile ==="
          echo ""
          
          read -p "Are you sure you want to destroy all releases? (yes/no): " confirm
          if [ "$confirm" != "yes" ]; then
            echo "Aborted"
            exit 1
          fi
          
          helmfile -f "$HELMFILE" destroy \
            --kube-context "$CONTEXT"
          
          echo ""
          echo "=== Helmfile destroy complete ==="
        '';
      };
    };
  };
}

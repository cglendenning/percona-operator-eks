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
  
  # Generate a helmfile release for a bundle
  generateRelease = batchName: batchConfig: bundleName: bundle:
    let
      releaseName = "${cfg.cluster.uniqueIdentifier}-${batchName}-${bundleName}";
      
      # For Helm charts, reference the chart directly
      chartRelease = if bundle.chart != null then {
        name = releaseName;
        namespace = bundle.namespace;
        chart = "${bundle.chart.package}";
        values = [ bundle.chart.values ];
        needs = map (dep: "${cfg.cluster.uniqueIdentifier}-${batchName}-${dep}") bundle.dependsOn;
      } else null;
      
      # For raw manifests, create a release that applies manifests via hooks
      manifestRelease = if (builtins.length bundle.manifests) > 0 then {
        name = releaseName;
        namespace = bundle.namespace;
        # Use a minimal chart with hooks to apply manifests
        chart = pkgs.runCommand "manifest-chart-${bundleName}" {} ''
          mkdir -p $out/templates
          
          # Combine all manifests
          cat ${lib.concatMapStringsSep " " (m: "${m}/manifest.yaml") bundle.manifests} \
            > $out/templates/manifests.yaml
          
          # Create Chart.yaml
          cat > $out/Chart.yaml << 'EOF'
          apiVersion: v2
          name: ${bundleName}
          version: 0.1.0
          description: Raw manifests for ${bundleName}
          EOF
        '';
        values = [ {} ];
        needs = map (dep: "${cfg.cluster.uniqueIdentifier}-${batchName}-${dep}") bundle.dependsOn;
      } else null;
      
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
      
      # Add batch dependencies to first release in batch
      releasesWithBatchDeps = if (builtins.length validReleases) > 0 then
        let
          firstRelease = builtins.head validReleases;
          restReleases = builtins.tail validReleases;
          batchDeps = map (dep: "${cfg.cluster.uniqueIdentifier}-${dep}-*") batchConfig.dependsOn;
          updatedFirstRelease = firstRelease // {
            needs = (firstRelease.needs or []) ++ batchDeps;
          };
        in
        [ updatedFirstRelease ] ++ restReleases
      else validReleases;
      
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
      
      # Generate all releases
      allReleases = lib.flatten (map (batchName:
        generateBatchReleases batchName batches.${batchName}
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
      default = pkgs.kubernetes-helmfile;
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
        runtimeInputs = [ pkgs.kubernetes-helmfile pkgs.kubernetes-helm pkgs.kubectl ];
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
          
          # Apply helmfile
          helmfile -f "$HELMFILE" apply \
            --kube-context "$CONTEXT" \
            --concurrency 1
          
          echo ""
          echo "=== Helmfile deployment complete ==="
        '';
      };
      
      # Generate diff script
      scripts.diff-helmfile = pkgs.writeShellApplication {
        name = "diff-${cfg.cluster.uniqueIdentifier}-helmfile";
        runtimeInputs = [ pkgs.kubernetes-helmfile pkgs.kubernetes-helm pkgs.kubectl ];
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
        runtimeInputs = [ pkgs.kubernetes-helmfile pkgs.kubernetes-helm pkgs.kubectl ];
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

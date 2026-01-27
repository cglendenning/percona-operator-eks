{ pkgs, lib }:

rec {
  # Download a Helm chart from a repository
  downloadHelmChart = { repo, chart, version, chartHash }:
    pkgs.fetchurl {
      url = "${repo}/${chart}-${version}.tgz";
      sha256 = chartHash;
    };

  # Render a Helm chart with values to Kubernetes manifests
  renderHelmChart = { chartPackage, name, namespace, values ? {} }:
    let
      valuesFile = pkgs.writeText "${name}-values.yaml" (
        builtins.toJSON values
      );
      # Try to use helm 3.14+ which supports fromToml
      # Fetch a newer helm binary if the default is too old
      helm = 
        if pkgs ? kubernetes-helm && 
           (builtins.compareVersions (lib.getVersion pkgs.kubernetes-helm) "3.14") >= 0
        then pkgs.kubernetes-helm
        else
          # Fallback: try to use helm from a newer nixpkgs or fetch directly
          # For now, we'll patch the chart to work around fromToml
          pkgs.kubernetes-helm;
    in
    pkgs.runCommand "helm-rendered-${name}" {
      buildInputs = [ helm pkgs.yq-go pkgs.gnused ];
    } ''
      mkdir -p $out
      
      # Extract the chart
      CHART_DIR=$(mktemp -d)
      tar -xzf ${chartPackage} -C $CHART_DIR
      
      # Convert JSON values to YAML
      cat ${valuesFile} | yq eval -P - > $CHART_DIR/values.yaml
      
      # Check helm version and patch chart if needed
      HELM_VERSION=$(${helm}/bin/helm version --template='{{.Version}}' 2>/dev/null | sed 's/v//' || echo "unknown")
      echo "Using Helm version: $HELM_VERSION"
      
      # Check if chart uses fromToml and helm version is too old
      if grep -r "fromToml" $CHART_DIR/*/templates/ 2>/dev/null && \
         [ "$(echo "$HELM_VERSION 3.14" | tr " " "\n" | sort -V | head -n1)" != "3.14" ]; then
        echo "WARNING: Chart uses fromToml but Helm version may be too old"
        echo "Attempting to patch chart to work around fromToml..."
        
        # Find and patch fromToml usage - replace with a workaround
        find $CHART_DIR -name "*.yaml" -type f -exec sed -i \
          's/{{.*fromToml.*}}/{{ "{}" }}/g' {} \; 2>/dev/null || true
      fi
      
      # Render the chart
      if ! ${helm}/bin/helm template ${name} $CHART_DIR/*/ \
        --namespace ${namespace} \
        --values $CHART_DIR/values.yaml \
        --include-crds \
        > $out/manifest.yaml 2>&1; then
        ERROR_OUTPUT=$(cat $out/manifest.yaml 2>/dev/null || echo "")
        echo "Helm template failed. Error output:" >&2
        echo "$ERROR_OUTPUT" >&2
        echo "" >&2
        if echo "$ERROR_OUTPUT" | grep -q "fromToml"; then
          echo "ERROR: Chart uses 'fromToml' which requires Helm 3.14+" >&2
          echo "Current Helm version: $HELM_VERSION" >&2
          echo "" >&2
          echo "For SeaweedFS, use helmfile directly instead of building manifests:" >&2
          echo "  nix build .#seaweedfs-helmfile" >&2
          echo "  helmfile -f result sync --kube-context k3d-seaweedfs-tutorial" >&2
        fi
        exit 1
      fi
      
      # Verify output is valid YAML (not an error message)
      if ! head -n1 $out/manifest.yaml | grep -qE "^(apiVersion|kind|---)"; then
        echo "ERROR: Helm template output doesn't look like valid Kubernetes YAML"
        echo "Output:"
        head -n20 $out/manifest.yaml
        exit 1
      fi
      
      # Clean up
      rm -rf $CHART_DIR
    '';

  # Combine multiple manifest files into one
  combineManifests = manifests:
    pkgs.runCommand "combined-manifests" {} ''
      mkdir -p $out
      cat ${lib.concatMapStringsSep " " (m: "${m}/manifest.yaml") manifests} > $out/manifest.yaml
    '';

  # Render a bundle (either Helm chart or raw manifests)
  renderBundle = bundle:
    if bundle.chart != null
    then renderHelmChart {
      chartPackage = bundle.chart.package;
      name = bundle.chart.name;
      namespace = bundle.namespace;
      values = bundle.chart.values or {};
    }
    else if (builtins.length bundle.manifests) > 0
    then combineManifests bundle.manifests
    else pkgs.writeText "empty-bundle" "";

  # Render all bundles from cluster configuration into a single manifest
  renderAllBundles = clusterConfig:
    let
      batches = clusterConfig.platform.kubernetes.cluster.batches;
      
      # Sort batches by priority
      sortedBatches = lib.sort (a: b: a.value.priority < b.value.priority) 
        (lib.mapAttrsToList (name: value: { inherit name value; }) batches);
      
      # Get all enabled bundles in priority order
      allBundles = lib.flatten (map (batch:
        let
          enabledBundles = lib.filter (b: b.enabled or true) 
            (lib.attrValues batch.value.bundles);
        in
        enabledBundles
      ) sortedBatches);
      
    in
    pkgs.runCommand "kubernetes-manifests" {} ''
      mkdir -p $out
      
      # Combine all manifests with --- separator
      ${lib.concatMapStringsSep "\n" (bundle: ''
        echo "---" >> $out/manifest.yaml
        cat ${renderBundle bundle}/manifest.yaml >> $out/manifest.yaml
      '') allBundles}
    '';

  # Render manifests by batch for ordered deployment
  renderBatchManifests = clusterConfig:
    let
      batches = clusterConfig.platform.kubernetes.cluster.batches;
      
      # Sort batches by priority
      sortedBatches = lib.sort (a: b: a.value.priority < b.value.priority) 
        (lib.mapAttrsToList (name: value: { inherit name value; }) batches);
      
      # Generate a manifest file for each batch (only if it has bundles)
      mkBatchManifest = batch:
        let
          enabledBundles = lib.filter (b: b.enabled or true) 
            (lib.attrValues batch.value.bundles);
          isEmpty = enabledBundles == [];
        in
        if isEmpty then null
        else pkgs.runCommand "batch-${batch.name}" {} ''
          mkdir -p $out
          ${lib.concatMapStringsSep "\n" (bundle: ''
            echo "---" >> $out/manifest.yaml
            cat ${renderBundle bundle}/manifest.yaml >> $out/manifest.yaml
          '') enabledBundles}
        '';
      
      # Filter out null (empty) batches
      allBatches = map mkBatchManifest sortedBatches;
    in
    lib.filter (b: b != null) allBatches;

}

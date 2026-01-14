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
    in
    pkgs.runCommand "helm-rendered-${name}" {
      buildInputs = [ pkgs.kubernetes-helm pkgs.yq-go ];
    } ''
      mkdir -p $out
      
      # Extract the chart
      CHART_DIR=$(mktemp -d)
      tar -xzf ${chartPackage} -C $CHART_DIR
      
      # Convert JSON values to YAML
      cat ${valuesFile} | yq eval -P - > $CHART_DIR/values.yaml
      
      # Render the chart
      helm template ${name} $CHART_DIR/*/ \
        --namespace ${namespace} \
        --values $CHART_DIR/values.yaml \
        --include-crds \
        > $out/manifest.yaml
      
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

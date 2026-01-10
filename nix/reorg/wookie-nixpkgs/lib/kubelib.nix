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
      cat ${lib.concatMapStringsSep " " (m: "${m}") manifests} > $out/manifest.yaml
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
}

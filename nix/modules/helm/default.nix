# Helm chart rendering module
#
# Provides functions for rendering Helm charts to Kubernetes manifests
# Exports: mkHelmChart
{ pkgs }:

{
  # Render a Helm chart to Kubernetes manifests
  mkHelmChart = {
    name,
    namespace ? "default",
    chart,
    repo ? null,
    version ? null,
    values ? { },
    createNamespace ? true,
  }:
    let
      yaml = pkgs.formats.yaml { };
      valuesFile = yaml.generate "${name}-values.yaml" values;
      
      repoAddCmd = if repo != null then
        "${pkgs.kubernetes-helm}/bin/helm repo add ${name}-repo ${repo} && ${pkgs.kubernetes-helm}/bin/helm repo update"
      else
        "echo 'No repo specified, using chart path directly'";
      
      chartRef = if repo != null then
        "${name}-repo/${chart}"
      else
        chart;
      
      versionFlag = if version != null then "--version ${version}" else "";
      
    in
    pkgs.runCommand "helm-${name}" {
      buildInputs = [ pkgs.kubernetes-helm ];
      # Set HOME and cache directories for Helm
      HOME = "$TMPDIR";
      XDG_CACHE_HOME = "$TMPDIR/.cache";
      XDG_CONFIG_HOME = "$TMPDIR/.config";
      XDG_DATA_HOME = "$TMPDIR/.local/share";
    } ''
      mkdir -p $out
      mkdir -p $HOME/.cache $HOME/.config $HOME/.local/share
      
      # Add repo if specified
      ${repoAddCmd}
      
      # Template the chart
      ${pkgs.kubernetes-helm}/bin/helm template ${name} ${chartRef} \
        --namespace ${namespace} \
        ${if createNamespace then "--create-namespace" else ""} \
        ${versionFlag} \
        --values ${valuesFile} \
        --include-crds \
        > $out/manifest.yaml
      
      echo "Chart ${name} rendered successfully"
    '';
}

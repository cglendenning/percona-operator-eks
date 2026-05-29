# Render victoria-metrics-k8s-stack Helm values (includes KSM customResourceState config).
# Copy with ksm-configmap.nix and k8s-monitoring-values.nix.
#
#   nix-build -E '
#     let
#       pkgs = import <nixpkgs> {};
#       lib = pkgs.lib;
#       render = import ./k8s-monitoring-helm-values.nix { inherit (pkgs) lib pkgs; };
#     in render.mkValuesYaml {
#       pmmWriteUrl = "https://monitoring-service.pmm.svc.cluster.local/victoriametrics/api/v1/write";
#       k8sClusterId = "my-cluster";
#     }
#   ' --no-out-link
#
#   helm upgrade --install vm-k8s-stack vm/victoria-metrics-k8s-stack \
#     --version 0.30.3 -f result/k8s-monitoring-values.yaml -n wookie-observability
{ lib ? null, pkgs }:
let
  yaml = pkgs.formats.yaml {};
  ksm = import ./ksm-configmap.nix { inherit lib pkgs; };

  mkValues = {
    pmmWriteUrl,
    k8sClusterId ? "default",
    nodeExporterEnabled ? false,
    tokenSecretName ? "pmm-service-account-token",
    tokenSecretKey ? "pmmservertoken",
  }:
    import ./k8s-monitoring-values.nix {
      inherit pmmWriteUrl k8sClusterId nodeExporterEnabled tokenSecretName tokenSecretKey;
      customResourceStateConfig = ksm.customResourceStateMetrics;
    };

  mkValuesYaml = args:
    pkgs.runCommand "k8s-monitoring-helm-values" { } ''
      mkdir -p $out
      cp ${yaml.generate "k8s-monitoring-values.yaml" (mkValues args)} $out/k8s-monitoring-values.yaml
    '';
in
{
  inherit mkValues mkValuesYaml;
}

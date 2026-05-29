# Victoria Metrics Operator CRDs required before VMAgent, VMServiceScrape, etc.
# Pin matches victoria-metrics-k8s-stack 0.30.x (operator subchart 0.39.x).
#
# Copy this file into your environment, then:
#
#   nix-build -E '
#     let
#       pkgs = import <nixpkgs> {};
#       vm = import ./vm-operator-crds.nix { inherit (pkgs) lib pkgs; };
#     in vm.mkCrdsManifest
#   ' --no-out-link
#
#   kubectl apply -f result/manifest.yaml
#   kubectl wait --for=condition=Established crd/vmagents.operator.victoriametrics.com --timeout=120s
#   kubectl wait --for=condition=Established crd/vmservicescrapes.operator.victoriametrics.com --timeout=120s
#
# Apply operator + VM CRs only after CRDs are Established.
{ lib ? null, pkgs }:
let
  # victoria-metrics-k8s-stack @ 0.30.3 depends on victoria-metrics-operator 0.39.*
  operatorChartVersion = "0.39.0";

  operatorChart = pkgs.fetchurl {
    url = "https://github.com/VictoriaMetrics/helm-charts/releases/download/victoria-metrics-operator-${operatorChartVersion}/victoria-metrics-operator-${operatorChartVersion}.tgz";
    sha256 = "sha256-aq5XO0xcnT0s6SaeUB8Z4AXA4pzHCBWeNohfoIB3JvA=";
  };

  # All 16 operator.victoriametrics.com CRDs ship in one multi-doc YAML inside the chart.
  crdsYamlPath = "victoria-metrics-operator/charts/crds/crds/crd.yaml";

  mkCrdsManifest = pkgs.runCommand "vm-operator-crds" { } ''
    mkdir -p $out
    tar -xOf ${operatorChart} ${crdsYamlPath} > $out/manifest.yaml
  '';
in
{
  inherit operatorChartVersion mkCrdsManifest;

  # Documented for sanity checks after apply:
  # vmagents, vmalerts, vmservicescrapes, vmnodescrapes, vmrules, vmsingles, vmclusters, ...
  expectedCrdCount = 16;
}

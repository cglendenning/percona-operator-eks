# Istio configuration module
#
# Provides minimal Istio configurations for k3d
# Exports: mkNamespace, mkIstioBase, mkIstiod, mkIstioGateway, defaultValues
{ pkgs }:

let
  helmLib = import ../helm/default.nix { inherit pkgs; };
in
{
  # Minimal values - let Helm charts handle defaults
  defaultValues = {
    base = {
      # Let chart use all defaults
    };
    
    istiod = {
      # Only override what's necessary for k3d
      pilot = {
        autoscaleEnabled = false;  # k3s doesn't support HPA v2
      };
    };
    
    gateway = {
      # Minimal overrides for k3d compatibility
      autoscaling = {
        enabled = false;  # k3s doesn't support HPA v2
      };
    };
  };

  # Create namespace first
  mkNamespace = {
    namespace ? "istio-system",
  }:
    let
      yaml = pkgs.formats.yaml { };
      manifest = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata = {
          name = namespace;
          labels = {
            "istio-injection" = "disabled";
          };
        };
      };
    in
    pkgs.runCommand "istio-namespace" { } ''
      mkdir -p $out
      cat ${yaml.generate "namespace.yaml" manifest} > $out/manifest.yaml
    '';

  # Render Istio base chart (CRDs)
  mkIstioBase = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istio-base";
      chart = "base";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.24.2";
      inherit namespace values;
      createNamespace = false;
    };

  # Render Istiod (control plane)
  mkIstiod = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istiod";
      chart = "istiod";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.24.2";
      inherit namespace values;
      createNamespace = false;
    };

  # Render Istio ingress gateway using official Helm chart
  mkIstioGateway = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istio-ingressgateway";
      chart = "gateway";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.24.2";
      inherit namespace values;
      createNamespace = false;
    };
}

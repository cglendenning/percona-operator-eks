# Istio configuration module
#
# Provides opinionated Istio configurations
# Exports: mkIstioBase, mkIstiod, mkIstioGateway, defaultValues
{ pkgs }:

let
  helmLib = import ../helm/default.nix { inherit pkgs; };
in
{
  # Default Istio values
  defaultValues = {
    base = {
      # Istio base chart (CRDs and cluster roles)
    };
    
    istiod = {
      # Istio control plane
      pilot = {
        resources = {
          requests = {
            cpu = "100m";
            memory = "128Mi";
          };
        };
      };
      meshConfig = {
        accessLogFile = "/dev/stdout";
      };
    };
    
    gateway = {
      # Istio ingress gateway
      service = {
        type = "LoadBalancer";
        ports = [
          { name = "http2"; port = 80; targetPort = 8080; }
          { name = "https"; port = 443; targetPort = 8443; }
        ];
      };
    };
  };

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
      createNamespace = true;
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

  # Render Istio ingress gateway
  mkIstioGateway = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istio-gateway";
      chart = "gateway";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.24.2";
      inherit namespace values;
      createNamespace = false;
    };
}

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
      # Minimal overrides for k3d/Docker compatibility
      autoscaling = {
        enabled = false;  # k3s doesn't support HPA v2
      };
      podSecurityContext = {
        sysctls = [];  # Disable sysctls for Docker/k3d
      };
    };
  };

  # Multi-cluster values for istiod
  mkMultiClusterValues = {
    clusterId,
    network ? null,
    meshId ? "mesh1",
  }:
    {
      pilot = {
        autoscaleEnabled = false;  # k3s doesn't support HPA v2
      };
      global = {
        meshID = meshId;
        multiCluster = {
          clusterName = clusterId;
        };
      } // (if network != null then {
        network = network;
      } else {});
    };

  # Create namespace first
  mkNamespace = {
    namespace ? "istio-system",
    network ? null,
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
          } // (if network != null then {
            "topology.istio.io/network" = network;
          } else {});
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

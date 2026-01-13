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
    gatewayAddresses ? {},
  }:
    {
      pilot = {
        autoscaleEnabled = false;  # k3s doesn't support HPA v2
      };
      meshConfig = {
        defaultConfig = {
          proxyMetadata = {
            ISTIO_META_DNS_CAPTURE = "true";
            ISTIO_META_DNS_AUTO_ALLOCATE = "true";
          };
        };
        meshNetworks = {
          network1 = {
            endpoints = [
              { fromRegistry = "cluster-a"; }
            ];
            gateways = if gatewayAddresses ? network1 then [
              {
                address = gatewayAddresses.network1;
                port = 15443;
              }
            ] else [
              {
                service = "istio-eastwestgateway.istio-system.svc.cluster.local";
                port = 15443;
              }
            ];
          };
          network2 = {
            endpoints = [
              { fromRegistry = "cluster-b"; }
            ];
            gateways = if gatewayAddresses ? network2 then [
              {
                address = gatewayAddresses.network2;
                port = 15443;
              }
            ] else [
              {
                service = "istio-eastwestgateway.istio-system.svc.cluster.local";
                port = 15443;
              }
            ];
          };
        };
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
      version = "1.28.2";
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
      version = "1.28.2";
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
      version = "1.28.2";
      inherit namespace values;
      createNamespace = false;
    };
}

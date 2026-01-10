{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.projects.wookie.istio;
  charts = import ../../../pkgs/charts/charts.nix { 
    kubelib = pkgs.kubelib;
    inherit lib;
  };

in
{
  options.projects.wookie.istio = {
    enable = mkEnableOption "Istio service mesh for Wookie";

    version = mkOption {
      type = types.str;
      default = "1_24_2";
      description = "Istio version to deploy (underscore notation).";
    };

    namespace = mkOption {
      type = types.str;
      default = "istio-system";
      description = "Namespace for Istio control plane.";
    };

    profile = mkOption {
      type = types.enum [ "minimal" "default" "demo" ];
      default = "default";
      description = "Istio installation profile.";
    };

    base = {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Install Istio base (CRDs).";
      };

      values = mkOption {
        type = types.attrs;
        default = {};
        description = "Additional values for istio-base chart.";
      };
    };

    istiod = {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Install Istiod (control plane).";
      };

      values = mkOption {
        type = types.attrs;
        default = {
          pilot = {
            autoscaleEnabled = false;
          };
        };
        description = "Additional values for istiod chart.";
      };
    };

    gateway = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Install Istio ingress gateway.";
      };

      values = mkOption {
        type = types.attrs;
        default = {
          autoscaling = {
            enabled = false;
          };
        };
        description = "Additional values for istio-gateway chart.";
      };
    };

    eastWestGateway = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Install Istio east-west gateway for multi-cluster.";
      };

      values = mkOption {
        type = types.attrs;
        default = {
          autoscaling = {
            enabled = false;
          };
        };
        description = "Additional values for east-west gateway.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Create istio-system namespace
    platform.kubernetes.cluster.batches.namespaces.bundles.istio-system = {
      namespace = cfg.namespace;
      manifests = [
        (pkgs.writeTextFile {
          name = "istio-namespace";
          text = ''
            apiVersion: v1
            kind: Namespace
            metadata:
              name: ${cfg.namespace}
              labels:
                istio-injection: disabled
          '';
        })
      ];
    };

    # Deploy Istio base (CRDs)
    platform.kubernetes.cluster.batches.crds.bundles.istio-base = mkIf cfg.base.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istio-base";
        version = cfg.version;
        package = charts.istio-base.${cfg.version};
        values = cfg.base.values;
      };
      dependsOn = [ "istio-system" ];
    };

    # Deploy Istiod (control plane)
    platform.kubernetes.cluster.batches.operators.bundles.istiod = mkIf cfg.istiod.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istiod";
        version = cfg.version;
        package = charts.istiod.${cfg.version};
        values = cfg.istiod.values;
      };
      dependsOn = [ "istio-base" ];
    };

    # Deploy Istio gateway (optional)
    platform.kubernetes.cluster.batches.services.bundles.istio-gateway = mkIf cfg.gateway.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istio-gateway";
        version = cfg.version;
        package = charts.istio-gateway.${cfg.version};
        values = cfg.gateway.values;
      };
      dependsOn = [ "istiod" ];
    };

    # Deploy East-West gateway for multi-cluster (optional)
    platform.kubernetes.cluster.batches.services.bundles.istio-eastwestgateway = mkIf cfg.eastWestGateway.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istio-eastwestgateway";
        version = cfg.version;
        package = charts.istio-gateway.${cfg.version};
        values = cfg.eastWestGateway.values;
      };
      dependsOn = [ "istiod" ];
    };
  };
}

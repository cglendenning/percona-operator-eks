{
  config,
  lib,
  name,
  kubelib,
  ...
}:
with lib;

{
  options = {
    name = mkOption {
      type = types.str;
      default = name;
      description = "Name of the bundle.";
    };

    namespace = mkOption {
      type = types.str;
      description = "Kubernetes namespace for the bundle.";
    };

    chart = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Chart name.";
          };

          version = mkOption {
            type = types.str;
            description = "Chart version (use underscore notation like 1_24_2).";
          };

          values = mkOption {
            type = types.attrs;
            default = {};
            description = "Helm values to override.";
          };

          package = mkOption {
            type = types.package;
            description = "Nix package containing the chart.";
          };
        };
      });
      default = null;
      description = "Helm chart configuration for this bundle.";
    };

    manifests = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Raw Kubernetes manifest packages to include.";
    };

    dependsOn = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of bundle names this bundle depends on.";
    };

    enabled = mkOption {
      type = types.bool;
      default = true;
      description = "Whether this bundle is enabled.";
    };
  };

  config = {
    # Bundle name defaults to attribute name
    name = mkDefault name;
  };
}

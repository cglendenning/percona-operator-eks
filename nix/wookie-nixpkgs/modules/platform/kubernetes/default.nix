{
  pkgs,
  lib,
  ...
}:
with lib;

let
  kubelib = pkgs.kubelib;

  # Bundle submodule (inline)
  bundle-submod = { name, ... }: {
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
              description = "Chart version (use underscore notation like 1_28_2).";
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
      name = mkDefault name;
    };
  };

  batch-submod = 
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Name of the batch.";
       };

        autoPrune = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether deleting bundles in this batch should prune all resources in the bundle.
            Currently set at batch level (so applies to all bundles).

            Generally batches for things like CRDs, Namespaces and Operators should have this set to false.
          '';
        };

        deleteNamespace = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether deleting bundles in this batch should delete the namespace.
          '';
        };

        priority = mkOption {
          type = types.number;
          default = 1;
        };

        dependsOn = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "List of batch names this batch depends on.";
        };

        bundles = mkOption {
          default = { };
          type = types.attrsOf (
            types.submoduleWith {
              modules = [ bundle-submod ];
              specialArgs = { inherit kubelib; };
            }
          );
        };
      };
    };
  
in
{
  imports = [
    ../backends/helmfile.nix
    ../seaweedfs/filer-sync.nix
  ];

  options = {
    build = mkOption {
      type = types.submodule {
        options = {
          scripts = mkOption {
            type = types.attrsOf types.package;
            default = {};
            description = "Build output scripts for cluster management.";
          };
          
          helmfile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Generated helmfile.yaml";
          };
          
          k3d = mkOption {
            type = types.attrs;
            default = {};
            description = "k3d cluster helper values (set by target modules).";
          };
        };
      };
      default = {};
      description = "Build outputs for the cluster.";
    };

    platform.kubernetes.cluster = mkOption {
      default = { };
      visible = false;
      type = types.submodule {
        options = {
          uniqueIdentifier = mkOption {
            type = types.str;
            description = ''
              Unique identifier for the cluster. Should be unique per build output.
              
              Will be used to distinguish between batches and batch dependencies
              that may get deployed to the same cluster.

              Examples:

              wookie-dev-full
              wookie-dev-ci-full
           '';

          };

          defaults = mkOption {
            type = types.submodule {
              options = {
                ingress = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Default ingress class.";
                };

                clusterIssuer = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Default cluster issuer.";
                };
              };
            };
            default = { };
           };

          batches = mkOption {
            default = { };
            type = types.attrsOf (
              types.submoduleWith {
                modules = [ batch-submod ];
                specialArgs = { inherit kubelib; };
              }
            );
          };
        };
      };
    };
  };

  config = {
    platform.kubernetes.cluster.batches = {
      namespaces = {
        priority = 100;
        autoPrune = false;
        bundles = { };
      };

      crds = {
        priority = 200;
        autoPrune = false;
        bundles = { };
      };

      operators = {
        priority = 300;
        autoPrune = false;
        bundles = { };
      };

      services = {
        priority = 600;
        bundles = { };
      };
    };
  };
}

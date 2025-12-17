{
  description = "DR Dashboard On-Prem Kubernetes manifests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Evaluate the module with configuration
        evalConfig = {
          registry ? "",
          imageTag ? "latest",
          namespace ? "default",
          serviceType ? "ClusterIP",
          nodePort ? null,
          ingressHost ? "wookie.eko.dev.cookie.com",
          ingressEnabled ? true,
          ingressClassName ? null,
          ingressTlsEnabled ? false,
          ingressTlsSecretName ? "dr-dashboard-tls"
        }:
          let
            evaluated = pkgs.lib.evalModules {
              modules = [
                ../nix/modules/dr-dashboard/default.nix
                ../nix/modules/dr-dashboard/manifests.nix
                {
                  dr-dashboard = {
                    enable = true;
                    image = {
                      inherit registry;
                      name = "dr-dashboard-on-prem";
                      tag = imageTag;
                      pullPolicy = if registry != "" then "Always" else "IfNotPresent";
                    };
                    inherit namespace;
                    service = {
                      type = serviceType;
                    } // pkgs.lib.optionalAttrs (nodePort != null) {
                      inherit nodePort;
                    };
                    ingress = {
                      enable = ingressEnabled;
                      host = ingressHost;
                    } // pkgs.lib.optionalAttrs (ingressClassName != null) {
                      className = ingressClassName;
                    } // {
                      tls = {
                        enable = ingressTlsEnabled;
                        secretName = ingressTlsSecretName;
                      };
                    };
                  };
                }
              ];
            };
          in
          evaluated.config.dr-dashboard.manifests;

        # Convert Nix attrset to YAML
        toYAML = pkgs.lib.generators.toYAML { };

        # Generate combined manifest file
        generateManifests = args:
          let
            manifests = evalConfig args;
            yamlDocs = pkgs.lib.mapAttrsToList
              (name: manifest: "---\n# ${name}\n${toYAML manifest}")
              manifests;
          in
          builtins.concatStringsSep "\n" yamlDocs;

        # Build manifest derivation
        buildManifests = args:
          pkgs.writeTextFile {
            name = "dr-dashboard-manifests";
            text = generateManifests args;
            destination = "/manifests.yaml";
          };

        # Default configuration - update registry to match your setup
        defaultArgs = {
          registry = "";  # Set your registry here, e.g., "ghcr.io/yourorg"
          imageTag = "latest";
          namespace = "default";
          serviceType = "ClusterIP";
          ingressEnabled = true;
          ingressHost = "wookie.eko.dev.cookie.com";
        };

      in
      {
        # Packages
        packages = {
          default = buildManifests defaultArgs;

          # Pre-configured variants
          local = buildManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            serviceType = "ClusterIP";
            ingressEnabled = true;
            ingressHost = "wookie.eko.dev.cookie.com";
          };

          nodeport = buildManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            serviceType = "NodePort";
            nodePort = 30080;
            ingressEnabled = false;
          };

          # With TLS enabled
          tls = buildManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            serviceType = "ClusterIP";
            ingressEnabled = true;
            ingressHost = "wookie.eko.dev.cookie.com";
            ingressTlsEnabled = true;
          };
        };

        # Dev shell with kubectl and useful tools
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            kubectl
            kubernetes-helm
            yq-go
          ];
        };

        # Lib functions for programmatic use
        lib = {
          inherit evalConfig generateManifests buildManifests;
        };
      }
    );
}


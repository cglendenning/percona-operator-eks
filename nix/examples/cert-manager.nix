# Example: Adding cert-manager via Helm module
#
# This demonstrates how to add a new Helm chart using the helm module.
# To use this, add it to your main flake.nix inputs and packages.

{
  description = "cert-manager module example";

  outputs = { self, ... }:
    {
      lib = { pkgs }: 
        let
          helmLib = import ../modules/helm/default.nix { inherit pkgs; };
        in
        {
          # Default cert-manager values
          defaultValues = {
            installCRDs = true;
            global = {
              leaderElection = {
                namespace = "cert-manager";
              };
            };
            prometheus = {
              enabled = true;
            };
          };

          # Create cert-manager installation
          mkCertManager = {
            namespace ? "cert-manager",
            values ? {},
          }:
            helmLib.mkHelmChart {
              name = "cert-manager";
              chart = "cert-manager";
              repo = "https://charts.jetstack.io";
              version = "v1.16.2";
              inherit namespace values;
              createNamespace = true;
            };
        };
    };
}

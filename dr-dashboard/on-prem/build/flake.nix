{
  description = "DR Dashboard On-Prem Kubernetes manifests";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          drDashboard = import ../nix/modules/dr-dashboard { inherit pkgs; };
        in
        {
          default = drDashboard.mkManifests {
            registry = "";
            imageTag = "latest";
            namespace = "default";
            ingressHost = "wookie.eko.dev.cookie.com";
          };
        }
      );
    };
}

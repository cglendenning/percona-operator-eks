{
  description = "DR Dashboard On-Prem Kubernetes manifests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    dr-dashboard.url = "git+ssh://git@github.com/OWNER/percona_operator?dir=dr-dashboard/on-prem/nix/modules/dr-dashboard";
  };

  outputs = { self, nixpkgs, dr-dashboard }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        {
          default = dr-dashboard.lib.${system}.mkManifests {
            imageTag = "latest";
            namespace = "default";
            ingressHost = "wookie.eko.dev.cookie.com";
          };
        }
      );
    };
}

{
  description = "DR Dashboard On-Prem Kubernetes manifests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    # For production: git+ssh://git@github.com/cglendenning/percona-operator-eks?dir=dr-dashboard/on-prem/nix/modules/dr-dashboard
    dr-dashboard.url = "path:../nix/modules/dr-dashboard";
  };

  outputs = { self, nixpkgs, dr-dashboard }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      namespace = "dr-dashboard";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          drDashboardLib = dr-dashboard.lib { inherit pkgs; };
        in
        {
          namespace = drDashboardLib.mkNamespace {
            inherit namespace;
          };

          webui = drDashboardLib.mkWebUI {
            imageTag = "latest";
            inherit namespace;
            ingressHost = "wookie.eko.dev.cookie.com";
          };

          default = pkgs.symlinkJoin {
            name = "dr-dashboard-all";
            paths = [ self.packages.${system}.namespace self.packages.${system}.webui ];
          };
        }
      );
    };
}

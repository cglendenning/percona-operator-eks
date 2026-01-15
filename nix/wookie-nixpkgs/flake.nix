{
  description = "Wookie NixPkgs - Kubernetes deployments with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      wookie = import ./default.nix { inherit nixpkgs; };
    in
    {
      # Export all packages from default.nix
      packages = wookie.packages;
      
      # Export all apps from default.nix
      apps = wookie.apps;
      
      # Export dev shells from default.nix
      devShells = wookie.devShells;
      
      # Export NixOS modules for reuse
      nixosModules = wookie.nixosModules;
      
      # Export library functions for advanced use (per-system for testAssertions)
      lib = forAllSystems (system: {
        inherit (wookie) mkConfig wookieLocalConfig clusterAConfig clusterBConfig;
        testAssertions = wookie.testAssertions.${system};
      });
    };
}

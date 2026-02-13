{
  description = "Trivial flake that fetches a GitHub repo (no duplicate system attrs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        src = pkgs.fetchFromGitHub {
          owner = "nix-community";
          repo  = "nixpkgs-fmt";
          rev   = "v1.3.0";
          sha256 = "sha256-w2FQq3m4xk5OaDPJwC0i4hGxwJ1x7bOeQyYhV9r8Gf8=";
        };
      in
      {
        packages = {
          src = src;

          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "fetched-src";
            version = "0.1.0";
            inherit src;

            installPhase = ''
              mkdir -p $out
              cp -R . $out/
            '';
          };
        };
      }
    );
}


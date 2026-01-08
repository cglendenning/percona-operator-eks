{
  description = "Helm chart rendering module";

  outputs = { self, ... }:
    {
      lib = { pkgs }: import ./default.nix { inherit pkgs; };
    };
}

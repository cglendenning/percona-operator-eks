{
  description = "k3d cluster management module";

  outputs = { self, ... }:
    {
      lib = { pkgs }: import ./default.nix { inherit pkgs; };
    };
}

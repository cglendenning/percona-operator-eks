{
  description = "DR Dashboard Kubernetes module";

  outputs = { self, ... }:
    {
      lib = { pkgs }: import ./default.nix { inherit pkgs; };
    };
}

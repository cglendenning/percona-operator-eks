{
  description = "Istio ServiceEntry module for cross-cluster services";

  outputs = { self, ... }:
    {
      lib = { pkgs }: import ./default.nix { inherit pkgs; };
    };
}

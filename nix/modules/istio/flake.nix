{
  description = "Istio Helm chart configuration module";

  outputs = { self, ... }:
    {
      lib = { pkgs }: import ./default.nix { inherit pkgs; };
    };
}

{
  kubelib,
  lib,
}:

let
  istio-repo = "https://istio-release.storage.googleapis.com/charts";

  # To get chart hashes:
  # 1. Use a fake hash (lib.fakeHash or any invalid hash)
  # 2. Try to build: nix build .#fleet-bundles
  # 3. Nix will error and show you the correct hash:
  #    "got: sha256-XXXXX..."
  # 4. Copy that hash here

in
{
  istio-base = {
    "1_24_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "base";
      version = "1.24.2";
      chartHash = lib.fakeHash;  # ← Replace with hash from nix build error
    };
  };

  istiod = {
    "1_24_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "istiod";
      version = "1.24.2";
      chartHash = lib.fakeHash;  # ← Replace with hash from nix build error
    };
  };

  istio-gateway = {
    "1_24_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "gateway";
      version = "1.24.2";
      chartHash = lib.fakeHash;  # ← Replace with hash from nix build error
    };
  };
}

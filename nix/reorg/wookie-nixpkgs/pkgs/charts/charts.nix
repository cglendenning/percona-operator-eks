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
    "1_28_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "base";
      version = "1.24.2";
      chartHash = "sha256-k5gf+Ra8Z6VVlGGXmV+3uDNIIotVmQ6V6HMwKfP9SA0="; 
    };
  };

  istiod = {
    "1_28_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "istiod";
      version = "1.24.2";
      chartHash = "sha256-euJBgNmg32AKohKc1NpKZw2R1hGsEgQJHqGDvd0JQVU="; 
    };
  };

  istio-gateway = {
    "1_28_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "gateway";
      version = "1.24.2";
      chartHash = "sha256-2wfu4sg+rHtoApBGLXa3MwWoGCzj0TRW8p37ObbHsEs=";
    };
  };
}

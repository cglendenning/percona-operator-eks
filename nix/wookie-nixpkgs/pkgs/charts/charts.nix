{
  kubelib,
  lib,
}:

let
  istio-repo = "https://istio-release.storage.googleapis.com/charts";
  seaweedfs-repo = "https://seaweedfs.github.io/seaweedfs/helm";

  # To get chart hashes:
  # 1. Use a fake hash (lib.fakeHash or any invalid hash)
  # 2. Try to build: nix build .#manifests
  # 3. Nix will error and show you the correct hash:
  #    "got: sha256-XXXXX..."
  # 4. Copy that hash here

in
{
  istio-base = {
    "1_28_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "base";
      version = "1.28.2";
      chartHash = "sha256-HAlpRi3Hm0ppPGMrp7rfWDkuPI0K+80bzHMnZwfhUUE=";
    };
  };

  istiod = {
    "1_28_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "istiod";
      version = "1.28.2";
      chartHash = "sha256-gPVKo48hRPMWIpqvzlXrulWHzQpWSy9228zgUC8JWRA=";
    };
  };

  istio-gateway = {
    "1_28_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "gateway";
      version = "1.28.2";
      chartHash = "sha256-2wfu4sg+rHtoApBGLXa3MwWoGCzj0TRW8p37ObbHsEs=";
    };
  };

  seaweedfs = {
    "4_0_406" = kubelib.downloadHelmChart {
      repo = seaweedfs-repo;
      chart = "seaweedfs";
      version = "4.0.406";
      chartHash = lib.fakeHash;
    };
  };
}

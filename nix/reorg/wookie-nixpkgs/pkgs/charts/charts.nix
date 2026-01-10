{
  kubelib,
}:

let
  istio-repo = "https://istio-release.storage.googleapis.com/charts";

in
{
  istio-base = {
    "1_24_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "base";
      version = "1.24.2";
      chartHash = "";
    };
  };

  istiod = {
    "1_24_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "istiod";
      version = "1.24.2";
      chartHash = "";
    };
  };

  istio-gateway = {
    "1_24_2" = kubelib.downloadHelmChart {
      repo = istio-repo;
      chart = "gateway";
      version = "1.24.2";
      chartHash = "";
    };
  };
}

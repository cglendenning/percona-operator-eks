{ ... }:

{
  resources.services."seaweedfs-filer-lb" = {
    apiVersion = "v1";
    kind = "Service";

    metadata = {
      name = "seaweedfs-filer-lb";
      namespace = "wookie-seaweed";
      annotations = {
        "external-dns.alpha.kubernetes.io/hostname" = "seaweedfs-filer.k3d.test";
      };
    };

    spec = {
      type = "LoadBalancer";

      selector = {
        "app.kubernetes.io/instance" = "seaweedfs";
        "app.kubernetes.io/name" = "seaweedfs";
      };

      ports = [
        {
          name = "http";
          protocol = "TCP";
          port = 8888;
          targetPort = 8888;
        }
        {
          name = "grpc";
          protocol = "TCP";
          port = 18888;
          targetPort = 18888;
        }
        {
          name = "metrics";
          protocol = "TCP";
          port = 9327;
          targetPort = 9327;
        }
      ];
    };
  };
}

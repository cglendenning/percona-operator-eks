# Profile: Multi-cluster primary cluster (Cluster A)
# This is the primary cluster in a multi-primary multi-network Istio mesh

[
  ../projects/wookie
  ../targets/multi-cluster-k3d.nix
  {
    targets.multi-cluster-k3d.enable = true;

    platform.kubernetes.cluster.uniqueIdentifier = "multi-cluster-a";

    projects.wookie = {
      enable = true;
      clusterRole = "primary";
      namespace = "demo";

      # Istio with east-west gateway
      istio = {
        enable = true;
        version = "1_28_2";
        profile = "default";
        
        istiod.values = {
          pilot = {
            autoscaleEnabled = false;
          };
          global = {
            meshID = "mesh1";
            multiCluster = {
              clusterName = "cluster-a";
            };
            network = "network1";
          };
        };

        eastWestGateway = {
          enabled = true;
          values = {
            autoscaling.enabled = false;
            replicaCount = 1;
            service = {
              type = "LoadBalancer";
              ports = [
                {
                  name = "status-port";
                  port = 15021;
                  targetPort = 15021;
                }
                {
                  name = "tls";
                  port = 15443;
                  targetPort = 15443;
                }
                {
                  name = "tls-istiod";
                  port = 15012;
                  targetPort = 15012;
                }
                {
                  name = "tls-webhook";
                  port = 15017;
                  targetPort = 15017;
                }
              ];
            };
            labels = {
              istio = "eastwestgateway";
              app = "istio-eastwestgateway";
              topology_istio_io_network = "network1";
            };
            env = {
              ISTIO_META_ROUTER_MODE = "sni-dnat";
              ISTIO_META_REQUESTED_NETWORK_VIEW = "network1";
            };
          };
        };
      };

      # Demo helloworld app
      demo-helloworld = {
        enable = true;
        namespace = "demo";
        replicas = 3;
      };
    };
  }
]

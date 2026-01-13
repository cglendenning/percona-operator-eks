# Istio configuration module
#
# Provides minimal Istio configurations for k3d
# Exports: mkNamespace, mkIstioBase, mkIstiod, mkIstioGateway, defaultValues
{ pkgs }:

let
  helmLib = import ../helm/default.nix { inherit pkgs; };
in
{
  # Minimal values - let Helm charts handle defaults
  defaultValues = {
    base = {
      # Let chart use all defaults
    };
    
    istiod = {
      # Only override what's necessary for k3d
      pilot = {
        autoscaleEnabled = false;  # k3s doesn't support HPA v2
      };
    };
    
    gateway = {
      # Minimal overrides for k3d/Docker compatibility
      autoscaling = {
        enabled = false;  # k3s doesn't support HPA v2
      };
      podSecurityContext = {
        sysctls = [];  # Disable sysctls for Docker/k3d
      };
    };
  };

  # Multi-cluster values for istiod
  mkMultiClusterValues = {
    clusterId,
    network ? null,
    meshId ? "mesh1",
    gatewayAddresses ? {},
  }:
    {
      pilot = {
        autoscaleEnabled = false;  # k3s doesn't support HPA v2
      };
      meshConfig = {
        defaultConfig = {
          proxyMetadata = {
            ISTIO_META_DNS_CAPTURE = "true";
            ISTIO_META_DNS_AUTO_ALLOCATE = "true";
          };
        };
        meshNetworks = {
          network1 = {
            endpoints = [
              { fromRegistry = "cluster-a"; }
            ];
            gateways = if gatewayAddresses ? network1 then [
              {
                address = gatewayAddresses.network1;
                port = 15443;
              }
            ] else [
              {
                service = "istio-eastwestgateway.istio-system.svc.cluster.local";
                port = 15443;
              }
            ];
          };
          network2 = {
            endpoints = [
              { fromRegistry = "cluster-b"; }
            ];
            gateways = if gatewayAddresses ? network2 then [
              {
                address = gatewayAddresses.network2;
                port = 15443;
              }
            ] else [
              {
                service = "istio-eastwestgateway.istio-system.svc.cluster.local";
                port = 15443;
              }
            ];
          };
        };
      };
      global = {
        meshID = meshId;
        multiCluster = {
          clusterName = clusterId;
        };
      } // (if network != null then {
        network = network;
      } else {});
    };

  # Create namespace first
  mkNamespace = {
    namespace ? "istio-system",
    network ? null,
  }:
    let
      yaml = pkgs.formats.yaml { };
      manifest = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata = {
          name = namespace;
          labels = {
            "istio-injection" = "disabled";
          } // (if network != null then {
            "topology.istio.io/network" = network;
          } else {});
        };
      };
    in
    pkgs.runCommand "istio-namespace" { } ''
      mkdir -p $out
      cat ${yaml.generate "namespace.yaml" manifest} > $out/manifest.yaml
    '';

  # Render Istio base chart (CRDs)
  mkIstioBase = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istio-base";
      chart = "base";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.28.2";
      inherit namespace values;
      createNamespace = false;
    };

  # Render Istiod (control plane)
  mkIstiod = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istiod";
      chart = "istiod";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.28.2";
      inherit namespace values;
      createNamespace = false;
    };

  # Render Istio ingress gateway using official Helm chart
  mkIstioGateway = {
    namespace ? "istio-system",
    values ? {},
  }:
    helmLib.mkHelmChart {
      name = "istio-ingressgateway";
      chart = "gateway";
      repo = "https://istio-release.storage.googleapis.com/charts";
      version = "1.28.2";
      inherit namespace values;
      createNamespace = false;
    };

  # Create east-west gateway for multi-cluster
  mkEastWestGateway = {
    namespace ? "istio-system",
    network ? "network1",
    nodePort ? 30443,
  }:
    let
      yaml = pkgs.formats.yaml { };
      serviceAccount = {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = "istio-eastwestgateway";
          inherit namespace;
        };
      };
      
      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          name = "istio-eastwestgateway";
          inherit namespace;
          labels = {
            istio = "eastwestgateway";
            "topology.istio.io/network" = network;
          };
        };
        spec = {
          type = "NodePort";
          selector = {
            istio = "eastwestgateway";
          };
          ports = [
            {
              port = 15021;
              name = "status-port";
              protocol = "TCP";
              targetPort = 15021;
              nodePort = 30021;
            }
            {
              port = 15443;
              name = "tls";
              protocol = "TCP";
              targetPort = 15443;
              inherit nodePort;
            }
            {
              port = 15012;
              name = "tcp-istiod";
              protocol = "TCP";
              targetPort = 15012;
              nodePort = 30012;
            }
            {
              port = 15017;
              name = "tcp-webhook";
              protocol = "TCP";
              targetPort = 15017;
              nodePort = 30017;
            }
          ];
        };
      };
      
      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "istio-eastwestgateway";
          inherit namespace;
        };
        spec = {
          replicas = 1;
          selector = {
            matchLabels = {
              istio = "eastwestgateway";
            };
          };
          template = {
            metadata = {
              labels = {
                istio = "eastwestgateway";
                "topology.istio.io/network" = network;
              };
              annotations = {
                "sidecar.istio.io/inject" = "false";
              };
            };
            spec = {
              serviceAccountName = "istio-eastwestgateway";
              containers = [{
                name = "istio-proxy";
                image = "docker.io/istio/proxyv2:1.28.2";
                args = [
                  "proxy"
                  "router"
                  "--domain"
                  "$(POD_NAMESPACE).svc.cluster.local"
                  "--proxyLogLevel=warning"
                  "--proxyComponentLogLevel=misc:error"
                  "--log_output_level=default:info"
                ];
                ports = [
                  { containerPort = 15021; protocol = "TCP"; }
                  { containerPort = 15443; protocol = "TCP"; }
                  { containerPort = 15012; protocol = "TCP"; }
                  { containerPort = 15017; protocol = "TCP"; }
                ];
                env = [
                  {
                    name = "POD_NAME";
                    valueFrom.fieldRef.fieldPath = "metadata.name";
                  }
                  {
                    name = "POD_NAMESPACE";
                    valueFrom.fieldRef.fieldPath = "metadata.namespace";
                  }
                  {
                    name = "INSTANCE_IP";
                    valueFrom.fieldRef.fieldPath = "status.podIP";
                  }
                  {
                    name = "SERVICE_ACCOUNT";
                    valueFrom.fieldRef.fieldPath = "spec.serviceAccountName";
                  }
                  {
                    name = "ISTIO_META_ROUTER_MODE";
                    value = "sni-dnat";
                  }
                  {
                    name = "ISTIO_META_REQUESTED_NETWORK_VIEW";
                    value = network;
                  }
                  {
                    name = "ISTIO_META_DNS_CAPTURE";
                    value = "true";
                  }
                  {
                    name = "ISTIO_META_DNS_AUTO_ALLOCATE";
                    value = "true";
                  }
                ];
                volumeMounts = [
                  { name = "istio-envoy"; mountPath = "/etc/istio/proxy"; }
                  { name = "config-volume"; mountPath = "/etc/istio/config"; }
                  { name = "istio-data"; mountPath = "/var/lib/istio/data"; }
                  { name = "podinfo"; mountPath = "/etc/istio/pod"; }
                  { name = "istiod-ca-cert"; mountPath = "/var/run/secrets/istio"; }
                ];
              }];
              volumes = [
                { name = "istio-envoy"; emptyDir = {}; }
                { name = "istio-data"; emptyDir = {}; }
                {
                  name = "podinfo";
                  downwardAPI.items = [
                    { path = "labels"; fieldRef.fieldPath = "metadata.labels"; }
                    { path = "annotations"; fieldRef.fieldPath = "metadata.annotations"; }
                  ];
                }
                {
                  name = "config-volume";
                  configMap = {
                    name = "istio";
                    optional = true;
                  };
                }
                {
                  name = "istiod-ca-cert";
                  configMap = {
                    name = "istio-ca-root-cert";
                    optional = true;
                  };
                }
              ];
            };
          };
        };
      };

      gateway = {
        apiVersion = "networking.istio.io/v1beta1";
        kind = "Gateway";
        metadata = {
          name = "cross-network-gateway";
          inherit namespace;
        };
        spec = {
          selector = {
            istio = "eastwestgateway";
          };
          servers = [{
            port = {
              number = 15443;
              name = "tls";
              protocol = "TLS";
            };
            tls.mode = "AUTO_PASSTHROUGH";
            hosts = [ "*.local" ];
          }];
        };
      };
    in
    pkgs.runCommand "istio-eastwestgateway" { } ''
      mkdir -p $out
      cat ${yaml.generate "serviceaccount.yaml" serviceAccount} > $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "service.yaml" service} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "deployment.yaml" deployment} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "gateway.yaml" gateway} >> $out/manifest.yaml
    '';

  # Create demo hello app
  mkDemoApp = {
    namespace ? "demo",
    network ? null,
  }:
    let
      yaml = pkgs.formats.yaml { };
      ns = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata = {
          name = namespace;
          labels = {
            "istio-injection" = "enabled";
          } // (if network != null then {
            "topology.istio.io/network" = network;
          } else {});
        };
      };
      
      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          name = "hello";
          inherit namespace;
          labels.app = "hello";
        };
        spec = {
          ports = [{
            port = 8080;
            name = "http";
          }];
          clusterIP = "None";
          selector.app = "hello";
        };
      };
      
      statefulset = {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        metadata = {
          name = "hello";
          inherit namespace;
        };
        spec = {
          serviceName = "hello";
          replicas = 3;
          selector.matchLabels.app = "hello";
          template = {
            metadata.labels.app = "hello";
            spec.containers = [{
              name = "hello";
              image = "docker.io/istio/examples-helloworld-v1:latest";
              ports = [{ containerPort = 8080; }];
              env = [{
                name = "SERVICE_VERSION";
                value = "v1";
              }];
            }];
          };
        };
      };
    in
    pkgs.runCommand "demo-app" { } ''
      mkdir -p $out
      cat ${yaml.generate "namespace.yaml" ns} > $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "service.yaml" service} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "statefulset.yaml" statefulset} >> $out/manifest.yaml
    '';
}

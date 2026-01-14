{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.projects.wookie.istio;
  charts = import ../../../pkgs/charts/charts.nix { 
    kubelib = pkgs.kubelib;
    inherit lib;
  };

in
{
  options.projects.wookie.istio = {
    enable = mkEnableOption "Istio service mesh for Wookie";

    version = mkOption {
      type = types.str;
      default = "1_28_2";
      description = "Istio version to deploy (underscore notation).";
    };

    namespace = mkOption {
      type = types.str;
      default = "istio-system";
      description = "Namespace for Istio control plane.";
    };

    profile = mkOption {
      type = types.enum [ "minimal" "default" "demo" ];
      default = "default";
      description = "Istio installation profile.";
    };

    base = {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Install Istio base (CRDs).";
      };

      values = mkOption {
        type = types.attrs;
        default = {};
        description = "Additional values for istio-base chart.";
      };
    };

    istiod = {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Install Istiod (control plane).";
      };

      values = mkOption {
        type = types.attrs;
        default = {
          pilot = {
            autoscaleEnabled = false;
          };
        };
        description = "Additional values for istiod chart.";
      };
    };

    gateway = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Install Istio ingress gateway.";
      };

      values = mkOption {
        type = types.attrs;
        default = {
          autoscaling = {
            enabled = false;
          };
        };
        description = "Additional values for istio-gateway chart.";
      };
    };

    eastWestGateway = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Install Istio east-west gateway for multi-cluster.";
      };

      values = mkOption {
        type = types.attrs;
        default = {
          autoscaling = {
            enabled = false;
          };
        };
        description = "Additional values for east-west gateway.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Create istio-system namespace
    platform.kubernetes.cluster.batches.namespaces.bundles.istio-system = {
      namespace = cfg.namespace;
      manifests = [
        (pkgs.writeTextFile {
          name = "istio-namespace";
          text = ''
            apiVersion: v1
            kind: Namespace
            metadata:
              name: ${cfg.namespace}
              labels:
                istio-injection: disabled
          '';
        })
      ];
    };

    # Deploy Istio base (CRDs)
    platform.kubernetes.cluster.batches.crds.bundles.istio-base = mkIf cfg.base.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istio-base";
        version = cfg.version;
        package = charts.istio-base.${cfg.version};
        values = cfg.base.values;
      };
      dependsOn = [ "istio-system" ];
    };

    # Deploy Istiod (control plane)
    platform.kubernetes.cluster.batches.operators.bundles.istiod = mkIf cfg.istiod.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istiod";
        version = cfg.version;
        package = charts.istiod.${cfg.version};
        values = cfg.istiod.values;
      };
      dependsOn = [ "istio-base" ];
    };

    # Deploy Istio gateway (optional)
    platform.kubernetes.cluster.batches.services.bundles.istio-gateway = mkIf cfg.gateway.enabled {
      namespace = cfg.namespace;
      chart = {
        name = "istio-gateway";
        version = cfg.version;
        package = charts.istio-gateway.${cfg.version};
        values = cfg.gateway.values;
      };
      dependsOn = [ "istiod" ];
    };

    # Deploy East-West gateway for multi-cluster (optional)
    # Uses raw manifests instead of Helm chart to avoid sidecar injection issues in k3d
    platform.kubernetes.cluster.batches.services.bundles.istio-eastwestgateway = mkIf cfg.eastWestGateway.enabled {
      namespace = cfg.namespace;
      manifests = [
        (let
          yaml = pkgs.formats.yaml { };
          version = builtins.replaceStrings ["_"] ["."] cfg.version;
          network = cfg.eastWestGateway.values.labels.topology_istio_io_network or "network1";
          routerMode = cfg.eastWestGateway.values.env.ISTIO_META_ROUTER_MODE or "sni-dnat";
          networkView = cfg.eastWestGateway.values.env.ISTIO_META_REQUESTED_NETWORK_VIEW or network;
          replicas = cfg.eastWestGateway.values.replicaCount or 1;
          
          # ServiceAccount
          serviceAccount = {
            apiVersion = "v1";
            kind = "ServiceAccount";
            metadata = {
              name = "istio-eastwestgateway";
              namespace = cfg.namespace;
            };
          };
          
          # Service
          service = {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "istio-eastwestgateway";
              namespace = cfg.namespace;
              labels = {
                istio = "eastwestgateway";
                "topology.istio.io/network" = network;
              };
            };
            spec = {
              type = "LoadBalancer";
              selector = {
                istio = "eastwestgateway";
              };
              ports = [
                {
                  port = 15021;
                  name = "status-port";
                  protocol = "TCP";
                  targetPort = 15021;
                }
                {
                  port = 15443;
                  name = "tls";
                  protocol = "TCP";
                  targetPort = 15443;
                }
                {
                  port = 15012;
                  name = "tcp-istiod";
                  protocol = "TCP";
                  targetPort = 15012;
                }
                {
                  port = 15017;
                  name = "tcp-webhook";
                  protocol = "TCP";
                  targetPort = 15017;
                }
              ];
            };
          };
          
          # Deployment
          deployment = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "istio-eastwestgateway";
              namespace = cfg.namespace;
            };
            spec = {
              replicas = replicas;
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
                  containers = [
                    {
                      name = "istio-proxy";
                      image = "docker.io/istio/proxyv2:${version}";
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
                          value = routerMode;
                        }
                        {
                          name = "ISTIO_META_REQUESTED_NETWORK_VIEW";
                          value = networkView;
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
                    }
                  ];
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
          
          # Gateway
          gateway = {
            apiVersion = "networking.istio.io/v1beta1";
            kind = "Gateway";
            metadata = {
              name = "cross-network-gateway";
              namespace = cfg.namespace;
            };
            spec = {
              selector = {
                istio = "eastwestgateway";
              };
              servers = [
                {
                  port = {
                    number = 15443;
                    name = "tls";
                    protocol = "TLS";
                  };
                  tls.mode = "AUTO_PASSTHROUGH";
                  hosts = [ "*.local" ];
                }
              ];
            };
          };
          
          # Combine all manifests
          allManifests = [
            serviceAccount
            service
            deployment
            gateway
          ];
          
        in
        pkgs.runCommand "istio-eastwestgateway-manifests" {} ''
          mkdir -p $out
          
          ${lib.concatMapStringsSep "\n" (manifest: ''
            echo "---" >> $out/manifest.yaml
            cat ${yaml.generate "manifest.yaml" manifest} >> $out/manifest.yaml
          '') allManifests}
        '')
      ];
      dependsOn = [ "istiod" ];
    };
  };
}

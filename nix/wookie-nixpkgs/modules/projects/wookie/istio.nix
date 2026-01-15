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

  # Istio helper functions for generating configurations
  yaml = pkgs.formats.yaml {};
  
  helpers = {
    # Bash function that generates meshNetworks ConfigMap at runtime
    # Usage: generate_mesh_config "$GW_A" "$GW_B" | kubectl apply -f -
    meshNetworksGenerator = pkgs.writeShellScript "generate-mesh-config" ''
      GW_A="$1"
      GW_B="$2"
      cat <<EOF
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: istio
        namespace: istio-system
      data:
        mesh: |-
          defaultConfig:
            discoveryAddress: istiod.istio-system.svc:15012
            proxyMetadata:
              ISTIO_META_DNS_CAPTURE: "true"
              ISTIO_META_DNS_AUTO_ALLOCATE: "true"
            tracing:
              zipkin:
                address: zipkin.istio-system:9411
          enablePrometheusMerge: true
          rootNamespace: istio-system
          trustDomain: cluster.local
          meshNetworks:
            network1:
              endpoints:
              - fromRegistry: cluster-a
              gateways:
              - address: $GW_A
                port: 15443
            network2:
              endpoints:
              - fromRegistry: cluster-b
              gateways:
              - address: $GW_B
                port: 15443
      EOF
    '';
    
    # Generate certificate authority structure
    mkCertificateScript = pkgs.writeShellScript "generate-ca-certs" (builtins.readFile ../../../lib/helpers/generate-ca-certs.sh);
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
    
    helpers = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
      description = "Helper functions for generating Istio configurations.";
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

  # Wookie project-level options (from default.nix)
  options.projects.wookie = {
    enable = mkEnableOption "Wookie project (PXC + Istio multi-cluster)";

    namespace = mkOption {
      type = types.str;
      default = "wookie";
      description = "Primary namespace for Wookie project resources.";
    };

    drNamespace = mkOption {
      type = types.str;
      default = "wookie-dr";
      description = "Disaster recovery namespace for Wookie project.";
    };

    clusterRole = mkOption {
      type = types.enum [ "primary" "dr" "standalone" ];
      default = "standalone";
      description = ''
        Role of this cluster in multi-cluster setup:
        - primary: Main production cluster
        - dr: Disaster recovery cluster
        - standalone: Single cluster deployment
      '';
    };

    # Demo helloworld options (from demo-helloworld.nix)
    demo-helloworld = {
      enable = mkEnableOption "Demo helloworld application for multi-cluster testing";

      namespace = mkOption {
        type = types.str;
        default = "demo";
        description = "Namespace for the helloworld application.";
      };

      replicas = mkOption {
        type = types.int;
        default = 3;
        description = "Number of helloworld replicas.";
      };

      version = mkOption {
        type = types.str;
        default = "v1";
        description = "Version label for the helloworld application.";
      };

      image = mkOption {
        type = types.str;
        default = "docker.io/istio/examples-helloworld-v1";
        description = "Container image for helloworld.";
      };
    };
  };

  config = mkMerge [
    # Export helpers (always available)
    {
      projects.wookie.istio.helpers = helpers;
    }
    
    # Istio configuration
    (mkIf cfg.enable {
    # Create istio-system namespace
    platform.kubernetes.cluster.batches.namespaces.bundles.istio-system = {
      namespace = cfg.namespace;
      manifests = [
        (let
          yaml = pkgs.formats.yaml { };
          # Extract network from eastWestGateway config (same as used for gateway deployment)
          network = if cfg.eastWestGateway.enabled
                    then cfg.eastWestGateway.values.labels.topology_istio_io_network or "network1"
                    else "network1";
          resource = {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = cfg.namespace;
              labels = {
                "istio-injection" = "disabled";
                "topology.istio.io/network" = network;
              };
            };
          };
        in
        pkgs.runCommand "istio-namespace" {} ''
          mkdir -p $out
          cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
        '')
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
      # Note: Namespaces are created via kubectl before helmfile runs
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
      # Note: Dependency on istiod is handled by batch-level dependency
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
          
          # ClusterRole for gateway
          clusterRole = {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            metadata = {
              name = "istio-eastwestgateway";
            };
            rules = [
              {
                apiGroups = [ "" ];
                resources = [ "pods" "nodes" "services" "endpoints" ];
                verbs = [ "get" "watch" "list" ];
              }
              {
                apiGroups = [ "" ];
                resources = [ "configmaps" ];
                verbs = [ "get" ];
              }
              {
                apiGroups = [ "certificates.k8s.io" ];
                resources = [ "certificatesigningrequests" ];
                verbs = [ "create" ];
              }
            ];
          };
          
          # ClusterRoleBinding
          clusterRoleBinding = {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRoleBinding";
            metadata = {
              name = "istio-eastwestgateway";
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "istio-eastwestgateway";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "istio-eastwestgateway";
                namespace = cfg.namespace;
              }
            ];
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
                        { name = "istio-token"; mountPath = "/var/run/secrets/tokens"; }
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
                    {
                      name = "istio-token";
                      projected = {
                        sources = [
                          {
                            serviceAccountToken = {
                              audience = "istio-ca";
                              expirationSeconds = 43200;
                              path = "istio-token";
                            };
                          }
                        ];
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
                  hosts = [ "*.local" "*.cluster.local" ];
                }
              ];
            };
          };
          
          # Combine all manifests
          allManifests = [
            serviceAccount
            clusterRole
            clusterRoleBinding
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
      # Note: Dependency on istiod is handled by batch-level dependency
    };
    })

    # Wookie project configuration
    (mkIf config.projects.wookie.enable {
      # Create wookie namespace
      platform.kubernetes.cluster.batches.namespaces.bundles.wookie-namespace = {
        namespace = config.projects.wookie.namespace;
        manifests = [
          (let
            yaml = pkgs.formats.yaml { };
            resource = {
              apiVersion = "v1";
              kind = "Namespace";
              metadata = {
                name = config.projects.wookie.namespace;
                labels = {
                  "istio-injection" = "enabled";
                  "wookie.io/cluster-role" = config.projects.wookie.clusterRole;
                };
              };
            };
          in
          pkgs.runCommand "wookie-namespace" {} ''
            mkdir -p $out
            cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
          '')
        ];
      };

      # Create wookie-dr namespace if in multi-cluster mode
      platform.kubernetes.cluster.batches.namespaces.bundles.wookie-dr-namespace = mkIf (config.projects.wookie.clusterRole != "standalone") {
        namespace = config.projects.wookie.drNamespace;
        manifests = [
          (let
            yaml = pkgs.formats.yaml { };
            resource = {
              apiVersion = "v1";
              kind = "Namespace";
              metadata = {
                name = config.projects.wookie.drNamespace;
                labels = {
                  "istio-injection" = "enabled";
                  "wookie.io/cluster-role" = config.projects.wookie.clusterRole;
                };
              };
            };
          in
          pkgs.runCommand "wookie-dr-namespace" {} ''
            mkdir -p $out
            cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
          '')
        ];
      };

      # Enable Istio by default for Wookie project
      projects.wookie.istio.enable = mkDefault true;
    })

    # Helloworld demo configuration
    (mkIf config.projects.wookie.demo-helloworld.enable (
      let
        demoCfg = config.projects.wookie.demo-helloworld;
      in {
        # Create namespace
        platform.kubernetes.cluster.batches.namespaces.bundles."helloworld-namespace" = {
          namespace = demoCfg.namespace;
          manifests = [
            (let
              yaml = pkgs.formats.yaml { };
              resource = {
                apiVersion = "v1";
                kind = "Namespace";
                metadata = {
                  name = demoCfg.namespace;
                  labels = {
                    "istio-injection" = "enabled";
                  };
                };
              };
            in
            pkgs.runCommand "helloworld-namespace" {} ''
              mkdir -p $out
              cp ${yaml.generate "manifest.yaml" resource} $out/manifest.yaml
            '')
          ];
        };

        # Deploy helloworld service and deployment
        platform.kubernetes.cluster.batches.services.bundles.helloworld = {
          namespace = demoCfg.namespace;
          manifests = [
            (let
              yaml = pkgs.formats.yaml { };
              
              service = {
                apiVersion = "v1";
                kind = "Service";
                metadata = {
                  name = "helloworld";
                  namespace = demoCfg.namespace;
                  labels = {
                    app = "helloworld";
                    service = "helloworld";
                  };
                };
                spec = {
                  ports = [
                    {
                      port = 5000;
                      name = "http";
                    }
                  ];
                  selector = {
                    app = "helloworld";
                  };
                };
              };
              
              deployment = {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "helloworld-${demoCfg.version}";
                  namespace = demoCfg.namespace;
                  labels = {
                    app = "helloworld";
                    version = demoCfg.version;
                  };
                };
                spec = {
                  replicas = demoCfg.replicas;
                  selector = {
                    matchLabels = {
                      app = "helloworld";
                      version = demoCfg.version;
                    };
                  };
                  template = {
                    metadata = {
                      labels = {
                        app = "helloworld";
                        version = demoCfg.version;
                      };
                    };
                    spec = {
                      containers = [
                        {
                          name = "helloworld";
                          image = demoCfg.image;
                          resources = {
                            requests = {
                              cpu = "100m";
                            };
                          };
                          imagePullPolicy = "IfNotPresent";
                          ports = [
                            {
                              containerPort = 5000;
                            }
                          ];
                          env = [
                            {
                              name = "SERVICE_VERSION";
                              value = demoCfg.version;
                            }
                          ];
                        }
                      ];
                    };
                  };
                };
              };
              
              serviceYaml = yaml.generate "service.yaml" service;
              deploymentYaml = yaml.generate "deployment.yaml" deployment;
            in
            pkgs.runCommand "helloworld-app" {} ''
              mkdir -p $out
              cat ${serviceYaml} > $out/manifest.yaml
              echo "---" >> $out/manifest.yaml
              cat ${deploymentYaml} >> $out/manifest.yaml
            '')
          ];
        };
      }
    ))
  ];
}

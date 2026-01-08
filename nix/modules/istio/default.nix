# Istio configuration module
#
# Provides opinionated Istio configurations
# Exports: mkNamespace, mkIstioBase, mkIstiod, mkIstioGateway, defaultValues
{ pkgs }:

let
  helmLib = import ../helm/default.nix { inherit pkgs; };
in
{
  # Default Istio values
  defaultValues = {
    base = {
      # Istio base chart (CRDs and cluster roles)
    };
    
    istiod = {
      # Istio control plane
      pilot = {
        autoscaleEnabled = false;  # Disable HPA for k3s compatibility
        resources = {
          requests = {
            cpu = "100m";
            memory = "128Mi";
          };
        };
      };
      meshConfig = {
        accessLogFile = "/dev/stdout";
      };
    };
    
    gateway = {
      # Istio ingress gateway
      autoscaling = {
        enabled = false;  # Disable HPA for k3s compatibility
      };
      replicaCount = 1;  # Single replica for local development
      
      # Use standard proxyv2 image instead of "auto" injection
      image = "docker.io/istio/proxyv2";
      tag = "1.24.2";
      
      # Disable injection template (it sets image to "auto")
      labels = {
        "sidecar.istio.io/inject" = "false";
      };
      
      securityContext = {
        # Disable privileged operations for Docker/k3d compatibility
        sysctls = [ ];
        runAsUser = 1337;
        runAsGroup = 1337;
        runAsNonRoot = true;
        fsGroup = 1337;
      };
      
      service = {
        type = "LoadBalancer";
        ports = [
          { name = "http2"; port = 80; targetPort = 8080; }
          { name = "https"; port = 443; targetPort = 8443; }
        ];
      };
    };
  };

  # Create namespace first
  mkNamespace = {
    namespace ? "istio-system",
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
          };
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
      version = "1.24.2";
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
      version = "1.24.2";
      inherit namespace values;
      createNamespace = false;
    };

  # Complete working gateway deployment for k3d
  mkIstioGateway = {
    namespace ? "istio-system",
    values ? {},
  }:
    let
      yaml = pkgs.formats.yaml { };
      
      serviceAccount = {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = "istio-ingressgateway";
          inherit namespace;
          labels = {
            app = "istio-ingressgateway";
            istio = "ingressgateway";
          };
        };
      };
      
      role = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        metadata = {
          name = "istio-ingressgateway";
          inherit namespace;
        };
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "get" "watch" "list" ];
          }
        ];
      };
      
      roleBinding = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        metadata = {
          name = "istio-ingressgateway";
          inherit namespace;
        };
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "istio-ingressgateway";
        };
        subjects = [{
          kind = "ServiceAccount";
          name = "istio-ingressgateway";
        }];
      };
      
      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "istio-ingressgateway";
          inherit namespace;
          labels = {
            app = "istio-ingressgateway";
            istio = "ingressgateway";
          };
        };
        spec = {
          replicas = 1;
          selector.matchLabels = {
            app = "istio-ingressgateway";
            istio = "ingressgateway";
          };
          template = {
            metadata = {
              labels = {
                app = "istio-ingressgateway";
                istio = "ingressgateway";
                "service.istio.io/canonical-name" = "istio-ingressgateway";
                "service.istio.io/canonical-revision" = "latest";
                "sidecar.istio.io/inject" = "false";
              };
              annotations = {
                "prometheus.io/port" = "15020";
                "prometheus.io/scrape" = "true";
                "prometheus.io/path" = "/stats/prometheus";
              };
            };
            spec = {
              serviceAccountName = "istio-ingressgateway";
              securityContext = {
                runAsUser = 1337;
                runAsGroup = 1337;
                runAsNonRoot = true;
                fsGroup = 1337;
              };
              containers = [{
                name = "istio-proxy";
                image = "docker.io/istio/proxyv2:1.24.2";
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
                  { containerPort = 15021; protocol = "TCP"; name = "status-port"; }
                  { containerPort = 8080; protocol = "TCP"; name = "http2"; }
                  { containerPort = 8443; protocol = "TCP"; name = "https"; }
                  { containerPort = 15090; protocol = "TCP"; name = "http-envoy-prom"; }
                ];
                env = [
                  { name = "JWT_POLICY"; value = "third-party-jwt"; }
                  { name = "PILOT_CERT_PROVIDER"; value = "istiod"; }
                  { name = "CA_ADDR"; value = "istiod.istio-system.svc:15012"; }
                  { name = "NODE_NAME"; valueFrom.fieldRef.fieldPath = "spec.nodeName"; }
                  { name = "POD_NAME"; valueFrom.fieldRef.fieldPath = "metadata.name"; }
                  { name = "POD_NAMESPACE"; valueFrom.fieldRef.fieldPath = "metadata.namespace"; }
                  { name = "INSTANCE_IP"; valueFrom.fieldRef.fieldPath = "status.podIP"; }
                  { name = "HOST_IP"; valueFrom.fieldRef.fieldPath = "status.hostIP"; }
                  { name = "SERVICE_ACCOUNT"; valueFrom.fieldRef.fieldPath = "spec.serviceAccountName"; }
                  { name = "ISTIO_META_WORKLOAD_NAME"; value = "istio-ingressgateway"; }
                  { name = "ISTIO_META_OWNER"; value = "kubernetes://apis/apps/v1/namespaces/istio-system/deployments/istio-ingressgateway"; }
                  { name = "ISTIO_META_MESH_ID"; value = "cluster.local"; }
                  { name = "TRUST_DOMAIN"; value = "cluster.local"; }
                  { name = "ISTIO_META_UNPRIVILEGED_POD"; value = "true"; }
                  { name = "ISTIO_META_CLUSTER_ID"; value = "Kubernetes"; }
                  { name = "ISTIO_META_NODE_NAME"; valueFrom.fieldRef.fieldPath = "spec.nodeName"; }
                ];
                readinessProbe = {
                  failureThreshold = 30;
                  httpGet = {
                    path = "/healthz/ready";
                    port = 15021;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 1;
                  periodSeconds = 2;
                  successThreshold = 1;
                  timeoutSeconds = 1;
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                  };
                  limits = {
                    cpu = "2000m";
                    memory = "1024Mi";
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities = {
                    drop = [ "ALL" ];
                  };
                  privileged = false;
                  readOnlyRootFilesystem = true;
                  runAsUser = 1337;
                  runAsGroup = 1337;
                  runAsNonRoot = true;
                };
                volumeMounts = [
                  {
                    name = "workload-socket";
                    mountPath = "/var/run/secrets/workload-spiffe-uds";
                  }
                  {
                    name = "credential-socket";
                    mountPath = "/var/run/secrets/credential-uds";
                  }
                  {
                    name = "workload-certs";
                    mountPath = "/var/run/secrets/workload-spiffe-credentials";
                  }
                  {
                    name = "istio-envoy";
                    mountPath = "/etc/istio/proxy";
                  }
                  {
                    name = "config-volume";
                    mountPath = "/etc/istio/config";
                  }
                  {
                    name = "istiod-ca-cert";
                    mountPath = "/var/run/secrets/istio";
                  }
                  {
                    name = "istio-token";
                    mountPath = "/var/run/secrets/tokens";
                    readOnly = true;
                  }
                  {
                    name = "istio-data";
                    mountPath = "/var/lib/istio/data";
                  }
                  {
                    name = "podinfo";
                    mountPath = "/etc/istio/pod";
                  }
                  {
                    name = "ingressgateway-certs";
                    mountPath = "/etc/istio/ingressgateway-certs";
                    readOnly = true;
                  }
                  {
                    name = "ingressgateway-ca-certs";
                    mountPath = "/etc/istio/ingressgateway-ca-certs";
                    readOnly = true;
                  }
                ];
              }];
              volumes = [
                {
                  name = "workload-socket";
                  emptyDir = {};
                }
                {
                  name = "credential-socket";
                  emptyDir = {};
                }
                {
                  name = "workload-certs";
                  emptyDir = {};
                }
                {
                  name = "istiod-ca-cert";
                  configMap = {
                    name = "istio-ca-root-cert";
                  };
                }
                {
                  name = "podinfo";
                  downwardAPI = {
                    items = [
                      {
                        path = "labels";
                        fieldRef.fieldPath = "metadata.labels";
                      }
                      {
                        path = "annotations";
                        fieldRef.fieldPath = "metadata.annotations";
                      }
                    ];
                  };
                }
                {
                  name = "istio-envoy";
                  emptyDir = {};
                }
                {
                  name = "istio-data";
                  emptyDir = {};
                }
                {
                  name = "istio-token";
                  projected = {
                    sources = [{
                      serviceAccountToken = {
                        path = "istio-token";
                        expirationSeconds = 43200;
                        audience = "istio-ca";
                      };
                    }];
                  };
                }
                {
                  name = "config-volume";
                  configMap = {
                    name = "istio";
                    optional = true;
                  };
                }
                {
                  name = "ingressgateway-certs";
                  secret = {
                    secretName = "istio-ingressgateway-certs";
                    optional = true;
                  };
                }
                {
                  name = "ingressgateway-ca-certs";
                  secret = {
                    secretName = "istio-ingressgateway-ca-certs";
                    optional = true;
                  };
                }
              ];
            };
          };
        };
      };
      
      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          name = "istio-ingressgateway";
          inherit namespace;
          labels = {
            app = "istio-ingressgateway";
            istio = "ingressgateway";
          };
        };
        spec = {
          type = "LoadBalancer";
          selector = {
            app = "istio-ingressgateway";
            istio = "ingressgateway";
          };
          ports = [
            { name = "status-port"; port = 15021; targetPort = 15021; protocol = "TCP"; }
            { name = "http2"; port = 80; targetPort = 8080; protocol = "TCP"; }
            { name = "https"; port = 443; targetPort = 8443; protocol = "TCP"; }
          ];
        };
      };
    in
    pkgs.runCommand "istio-ingressgateway" { } ''
      mkdir -p $out
      cat ${yaml.generate "serviceaccount.yaml" serviceAccount} > $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "role.yaml" role} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "rolebinding.yaml" roleBinding} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "service.yaml" service} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "deployment.yaml" deployment} >> $out/manifest.yaml
    '';
}

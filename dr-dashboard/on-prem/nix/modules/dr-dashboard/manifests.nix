# Kubernetes manifest generation for DR Dashboard
{ lib, config, ... }:

let
  cfg = config.dr-dashboard;

  # Build full image reference
  imageRef =
    if cfg.image.registry != ""
    then "${cfg.image.registry}/${cfg.image.name}:${cfg.image.tag}"
    else "${cfg.image.name}:${cfg.image.tag}";

  # Common labels
  labels = {
    app = "dr-dashboard";
    environment = "on-prem";
  } // cfg.extraLabels;

  # Deployment manifest
  deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "dr-dashboard-on-prem";
      namespace = cfg.namespace;
      inherit labels;
    };
    spec = {
      replicas = cfg.replicas;
      selector.matchLabels = {
        app = "dr-dashboard";
        environment = "on-prem";
      };
      template = {
        metadata.labels = labels;
        spec = {
          containers = [{
            name = "dr-dashboard";
            image = imageRef;
            imagePullPolicy = cfg.image.pullPolicy;
            ports = [{
              containerPort = 8080;
              name = "http";
            }];
            env = [
              { name = "PORT"; value = "8080"; }
              { name = "DATA_DIR"; value = "/app/data"; }
              { name = "STATIC_DIR"; value = "/app/static"; }
            ];
            resources = {
              requests = {
                memory = cfg.resources.requests.memory;
                cpu = cfg.resources.requests.cpu;
              };
              limits = {
                memory = cfg.resources.limits.memory;
                cpu = cfg.resources.limits.cpu;
              };
            };
            livenessProbe = {
              httpGet = {
                path = "/";
                port = "http";
              };
              initialDelaySeconds = 5;
              periodSeconds = 30;
            };
            readinessProbe = {
              httpGet = {
                path = "/";
                port = "http";
              };
              initialDelaySeconds = 3;
              periodSeconds = 10;
            };
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 1000;
              readOnlyRootFilesystem = true;
              allowPrivilegeEscalation = false;
            };
          }];
          securityContext = {
            fsGroup = 1000;
          };
        } // lib.optionalAttrs (cfg.imagePullSecrets != [ ]) {
          imagePullSecrets = map (name: { inherit name; }) cfg.imagePullSecrets;
        };
      };
    };
  };

  # Service manifest
  service = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "dr-dashboard-on-prem";
      namespace = cfg.namespace;
      inherit labels;
    };
    spec = {
      type = cfg.service.type;
      ports = [{
        port = cfg.service.port;
        targetPort = "http";
        protocol = "TCP";
        name = "http";
      } // lib.optionalAttrs (cfg.service.type == "NodePort" && cfg.service.nodePort != null) {
        nodePort = cfg.service.nodePort;
      }];
      selector = {
        app = "dr-dashboard";
        environment = "on-prem";
      };
    };
  };

  # Namespace manifest (only if not default)
  namespace = lib.optionalAttrs (cfg.namespace != "default") {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = {
      name = cfg.namespace;
      labels = labels;
    };
  };

  # Ingress manifest
  ingress = lib.optionalAttrs (cfg.ingress.enable && cfg.ingress.host != "") {
    apiVersion = "networking.k8s.io/v1";
    kind = "Ingress";
    metadata = {
      name = "dr-dashboard-on-prem";
      namespace = cfg.namespace;
      labels = labels;
    } // lib.optionalAttrs (cfg.ingress.annotations != { }) {
      annotations = cfg.ingress.annotations;
    };
    spec = {
      rules = [{
        host = cfg.ingress.host;
        http = {
          paths = [{
            path = cfg.ingress.path;
            pathType = cfg.ingress.pathType;
            backend = {
              service = {
                name = "dr-dashboard-on-prem";
                port = {
                  name = "http";
                };
              };
            };
          }];
        };
      }];
    } // lib.optionalAttrs (cfg.ingress.className != null) {
      ingressClassName = cfg.ingress.className;
    } // lib.optionalAttrs cfg.ingress.tls.enable {
      tls = [{
        hosts = [ cfg.ingress.host ];
        secretName = cfg.ingress.tls.secretName;
      }];
    };
  };

in
{
  config = lib.mkIf cfg.enable {
    # Export manifests as module outputs
    dr-dashboard.manifests = {
      inherit deployment service;
    } // lib.optionalAttrs (cfg.namespace != "default") {
      inherit namespace;
    } // lib.optionalAttrs (cfg.ingress.enable && cfg.ingress.host != "") {
      inherit ingress;
    };
  };

  options.dr-dashboard.manifests = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = { };
    description = "Generated Kubernetes manifests";
    readOnly = true;
  };
}


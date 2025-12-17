# Nix module for DR Dashboard Kubernetes deployment
{ lib, ... }:

with lib;

{
  options.dr-dashboard = {
    enable = mkEnableOption "DR Dashboard deployment";

    image = {
      registry = mkOption {
        type = types.str;
        default = "";
        description = "Container registry (empty for local/default registry)";
        example = "ghcr.io/myorg";
      };

      name = mkOption {
        type = types.str;
        default = "dr-dashboard-on-prem";
        description = "Image name";
      };

      tag = mkOption {
        type = types.str;
        default = "latest";
        description = "Image tag";
      };

      pullPolicy = mkOption {
        type = types.enum [ "Always" "IfNotPresent" "Never" ];
        default = "IfNotPresent";
        description = "Image pull policy";
      };
    };

    namespace = mkOption {
      type = types.str;
      default = "default";
      description = "Kubernetes namespace for deployment";
    };

    replicas = mkOption {
      type = types.int;
      default = 1;
      description = "Number of replicas";
    };

    service = {
      type = mkOption {
        type = types.enum [ "ClusterIP" "NodePort" "LoadBalancer" ];
        default = "ClusterIP";
        description = "Kubernetes service type";
      };

      port = mkOption {
        type = types.int;
        default = 80;
        description = "Service port";
      };

      nodePort = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "NodePort (only used when service.type is NodePort)";
      };
    };

    resources = {
      requests = {
        memory = mkOption {
          type = types.str;
          default = "32Mi";
          description = "Memory request";
        };

        cpu = mkOption {
          type = types.str;
          default = "10m";
          description = "CPU request";
        };
      };

      limits = {
        memory = mkOption {
          type = types.str;
          default = "128Mi";
          description = "Memory limit";
        };

        cpu = mkOption {
          type = types.str;
          default = "100m";
          description = "CPU limit";
        };
      };
    };

    extraLabels = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional labels to apply to resources";
    };

    imagePullSecrets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "List of image pull secret names";
      example = [ "registry-credentials" ];
    };

    ingress = {
      enable = mkEnableOption "Ingress resource";

      host = mkOption {
        type = types.str;
        default = "";
        description = "Ingress hostname";
        example = "wookie.eko.dev.cookie.com";
      };

      className = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Ingress class name (e.g., nginx, traefik)";
      };

      annotations = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Ingress annotations";
        example = {
          "kubernetes.io/ingress.class" = "nginx";
          "cert-manager.io/cluster-issuer" = "letsencrypt-prod";
        };
      };

      tls = {
        enable = mkEnableOption "TLS for ingress";

        secretName = mkOption {
          type = types.str;
          default = "dr-dashboard-tls";
          description = "TLS secret name";
        };
      };

      path = mkOption {
        type = types.str;
        default = "/";
        description = "Ingress path";
      };

      pathType = mkOption {
        type = types.enum [ "Prefix" "Exact" "ImplementationSpecific" ];
        default = "Prefix";
        description = "Ingress path type";
      };
    };
  };
}


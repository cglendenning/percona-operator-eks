# DR Dashboard Kubernetes module
#
# Generates Kubernetes manifests for deploying dr-dashboard.
# Exports: mkNamespace, mkWebUI
{ pkgs }:

let
  cfg = import ./config.nix;
  yaml = pkgs.formats.yaml { };
in
{
  mkNamespace = { namespace }:
    let
      manifest = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata = {
          name = namespace;
          labels = cfg.labels;
        };
      };
    in
    pkgs.runCommand "dr-dashboard-namespace" { } ''
      mkdir -p $out
      cat ${yaml.generate "namespace.yaml" manifest} > $out/manifest.yaml
    '';

  mkWebUI = {
    imageTag ? "latest",
    namespace ? "default",
    ingressHost ? "",
    labels ? cfg.labels,
  }:
    let
      image = if cfg.registry != ""
        then "${cfg.registry}/${cfg.imageName}:${imageTag}"
        else "${cfg.imageName}:${imageTag}";

      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { name = cfg.name; inherit namespace labels; };
        spec = {
          replicas = 1;
          selector.matchLabels = labels;
          template = {
            metadata.labels = labels;
            spec = {
              containers = [{
                name = "dr-dashboard";
                inherit image;
                imagePullPolicy = if cfg.registry != "" then "Always" else "IfNotPresent";
                ports = [{ containerPort = cfg.containerPort; name = "http"; }];
                env = [
                  { name = "PORT"; value = toString cfg.containerPort; }
                  { name = "DATA_DIR"; value = "/app/data"; }
                  { name = "STATIC_DIR"; value = "/app/static"; }
                ];
                resources = cfg.resources;
                livenessProbe = {
                  httpGet = { path = "/"; port = "http"; };
                  initialDelaySeconds = 5;
                  periodSeconds = 30;
                };
                readinessProbe = {
                  httpGet = { path = "/"; port = "http"; };
                  initialDelaySeconds = 3;
                  periodSeconds = 10;
                };
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = cfg.runAsUser;
                  readOnlyRootFilesystem = true;
                  allowPrivilegeEscalation = false;
                };
              }];
              securityContext.fsGroup = cfg.fsGroup;
            };
          };
        };
      };

      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = { name = cfg.name; inherit namespace labels; };
        spec = {
          type = "ClusterIP";
          ports = [{ port = cfg.servicePort; targetPort = "http"; protocol = "TCP"; name = "http"; }];
          selector = labels;
        };
      };

      ingress = {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        metadata = { name = cfg.name; inherit namespace labels; };
        spec.rules = [{
          host = ingressHost;
          http.paths = [{
            path = "/";
            pathType = "Prefix";
            backend.service = { name = cfg.name; port.name = "http"; };
          }];
        }];
      };

    in
    pkgs.runCommand "dr-dashboard-webui" { } ''
      mkdir -p $out
      echo "---" > $out/manifest.yaml
      cat ${yaml.generate "deployment.yaml" deployment} >> $out/manifest.yaml
      echo "---" >> $out/manifest.yaml
      cat ${yaml.generate "service.yaml" service} >> $out/manifest.yaml
      ${pkgs.lib.optionalString (ingressHost != "") ''
        echo "---" >> $out/manifest.yaml
        cat ${yaml.generate "ingress.yaml" ingress} >> $out/manifest.yaml
      ''}
    '';
}

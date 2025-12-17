# DR Dashboard Kubernetes module
#
# Generates Kubernetes manifests for deploying dr-dashboard.
# Import and call with: mkManifests pkgs { registry = "..."; ... }
{ pkgs }:

{
  mkManifests = {
    registry ? "",
    imageTag ? "latest",
    namespace ? "default",
    ingressHost ? "",
    labels ? { app = "dr-dashboard"; environment = "on-prem"; },
  }:
    let
      yaml = pkgs.formats.yaml { };

      image = if registry != ""
        then "${registry}/dr-dashboard-on-prem:${imageTag}"
        else "dr-dashboard-on-prem:${imageTag}";

      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { name = "dr-dashboard-on-prem"; inherit namespace labels; };
        spec = {
          replicas = 1;
          selector.matchLabels = labels;
          template = {
            metadata.labels = labels;
            spec = {
              containers = [{
                name = "dr-dashboard";
                inherit image;
                imagePullPolicy = if registry != "" then "Always" else "IfNotPresent";
                ports = [{ containerPort = 8080; name = "http"; }];
                env = [
                  { name = "PORT"; value = "8080"; }
                  { name = "DATA_DIR"; value = "/app/data"; }
                  { name = "STATIC_DIR"; value = "/app/static"; }
                ];
                resources = {
                  requests = { memory = "32Mi"; cpu = "10m"; };
                  limits = { memory = "128Mi"; cpu = "100m"; };
                };
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
                  runAsUser = 1000;
                  readOnlyRootFilesystem = true;
                  allowPrivilegeEscalation = false;
                };
              }];
              securityContext.fsGroup = 1000;
            };
          };
        };
      };

      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = { name = "dr-dashboard-on-prem"; inherit namespace labels; };
        spec = {
          type = "ClusterIP";
          ports = [{ port = 80; targetPort = "http"; protocol = "TCP"; name = "http"; }];
          selector = labels;
        };
      };

      ingress = {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        metadata = { name = "dr-dashboard-on-prem"; inherit namespace labels; };
        spec.rules = [{
          host = ingressHost;
          http.paths = [{
            path = "/";
            pathType = "Prefix";
            backend.service = { name = "dr-dashboard-on-prem"; port.name = "http"; };
          }];
        }];
      };

    in
    pkgs.runCommand "dr-dashboard-manifests" { } ''
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

{
  description = "DR Dashboard On-Prem Kubernetes manifests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          yaml = pkgs.formats.yaml { };

          mkManifests = {
            registry ? "",
            imageTag ? "latest",
            namespace ? "default",
            ingressHost ? "wookie.eko.dev.cookie.com",
          }:
            let
              image = if registry != "" 
                then "${registry}/dr-dashboard-on-prem:${imageTag}"
                else "dr-dashboard-on-prem:${imageTag}";

              labels = { app = "dr-dashboard"; environment = "on-prem"; };

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
              echo "---" > $out/manifests.yaml
              cat ${yaml.generate "deployment.yaml" deployment} >> $out/manifests.yaml
              echo "---" >> $out/manifests.yaml
              cat ${yaml.generate "service.yaml" service} >> $out/manifests.yaml
              echo "---" >> $out/manifests.yaml
              cat ${yaml.generate "ingress.yaml" ingress} >> $out/manifests.yaml
            '';

        in {
          default = mkManifests { };
        }
      );

      lib = forAllSystems (system: {
        mkManifests = args:
          self.packages.${system}.default.override args;
      });
    };
}

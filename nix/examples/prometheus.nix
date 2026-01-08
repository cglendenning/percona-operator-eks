# Example: Adding Prometheus via Helm module
#
# This demonstrates adding the kube-prometheus-stack.
# Shows more complex values configuration.

{
  description = "Prometheus stack module example";

  outputs = { self, ... }:
    {
      lib = { pkgs }:
        let
          helmLib = import ../modules/helm/default.nix { inherit pkgs; };
        in
        {
          # Default Prometheus stack values
          defaultValues = {
            prometheus = {
              prometheusSpec = {
                retention = "30d";
                storageSpec = {
                  volumeClaimTemplate = {
                    spec = {
                      accessModes = [ "ReadWriteOnce" ];
                      resources = {
                        requests = {
                          storage = "50Gi";
                        };
                      };
                    };
                  };
                };
                serviceMonitorSelectorNilUsesHelmValues = false;
              };
            };
            grafana = {
              enabled = true;
              adminPassword = "admin";
              persistence = {
                enabled = true;
                size = "10Gi";
              };
            };
            alertmanager = {
              enabled = true;
            };
          };

          # Create Prometheus stack
          mkPrometheusStack = {
            namespace ? "monitoring",
            values ? {},
          }:
            helmLib.mkHelmChart {
              name = "kube-prometheus-stack";
              chart = "kube-prometheus-stack";
              repo = "https://prometheus-community.github.io/helm-charts";
              version = "68.2.2";
              inherit namespace values;
              createNamespace = true;
            };
        };
    };
}

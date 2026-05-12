{
  description = "Prometheus scrape (mock Seaweed filer) -> OTEL Collector -> OTLP HTTP (mock Grafana)";

  # Unstable tracks current collector packaging (`otelcol-contrib`); pin in flake.lock for reproducibility.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          demoPy = ./demo.py;

          filerPort = 9333;
          otlpHttpPort = 4318;

          # Receiver wiring lives here: Nix generates the YAML so scrape targets and
          # intervals stay reviewable and parameterizable (ports, labels, TLS, etc.).
          yamlFmt = pkgs.formats.yaml { };
          otelCollectorConfig = yamlFmt.generate "otel-collector.yaml" {
            receivers = {
              prometheus = {
                config = {
                  scrape_configs = [
                    {
                      job_name = "seaweed-filer-mock";
                      scrape_interval = "5s";
                      metrics_path = "/metrics";
                      static_configs = [
                        { targets = [ "127.0.0.1:${toString filerPort}" ]; }
                      ];
                    }
                  ];
                };
              };
            };
            processors = {
              batch = { };
            };
            exporters = {
              otlphttp = {
                endpoint = "http://127.0.0.1:${toString otlpHttpPort}";
                tls.insecure = true;
              };
              debug = {
                verbosity = "detailed";
              };
            };
            service = {
              pipelines = {
                metrics = {
                  receivers = [ "prometheus" ];
                  processors = [ "batch" ];
                  exporters = [
                    "otlphttp"
                    "debug"
                  ];
                };
              };
            };
          };

          otelBin = pkgs.lib.getExe pkgs.opentelemetry-collector-contrib;

          demo = pkgs.writeShellApplication {
            name = "otel-seaweed-demo";
            runtimeInputs = [
              pkgs.python3
              pkgs.opentelemetry-collector-contrib
              pkgs.curl
            ];
            text = ''
              set -euo pipefail

              cleanup() {
                local ec=$?
                for pid in "''${filer_pid:-}" "''${sink_pid:-}"; do
                  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    kill "$pid" 2>/dev/null || true
                    local j=0
                    while [[ $j -lt 20 ]] && kill -0 "$pid" 2>/dev/null; do
                      sleep 0.05
                      j=$((j + 1))
                    done
                    kill -9 "$pid" 2>/dev/null || true
                  fi
                done
                exit "$ec"
              }
              trap cleanup EXIT INT TERM

              CONFIG=${otelCollectorConfig}
              DEMO_PY=${demoPy}

              python3 "$DEMO_PY" filer --port ${toString filerPort} &
              filer_pid=$!
              python3 "$DEMO_PY" sink --port ${toString otlpHttpPort} &
              sink_pid=$!

              echo "Waiting for mock filer /metrics..."
              ok=
              i=0
              while [[ $i -lt 50 ]]; do
                if curl --silent --fail "http://127.0.0.1:${toString filerPort}/metrics" >/dev/null; then
                  ok=1
                  break
                fi
                sleep 0.1
                i=$((i + 1))
              done
              if [[ -z "$ok" ]]; then
                echo "Timed out waiting for filer mock" >&2
                exit 1
              fi

              echo "Starting otelcol-contrib with $CONFIG"
              exec ${otelBin} --config="file:$CONFIG"
            '';
          };
        in
        {
          inherit demo;
          default = demo;
        }
      );

      apps = forAllSystems (
        system:
        let
          inherit (self.packages.${system}) demo;
        in
        {
          default = {
            type = "app";
            program = "${demo}/bin/otel-seaweed-demo";
          };
        }
      );
    };
}

# OTEL Collector demo: Seaweed-style Prometheus scrape to OTLP (Grafana-style sink)

This is a **local learning stack** with no Kubernetes or Docker: a tiny Python filer mock exposes Prometheus text at `/metrics`, **OpenTelemetry Collector Contrib** scrapes it with the built-in **Prometheus receiver**, and forwards metrics over **OTLP/HTTP** to another Python process that stands in for **Grafana OTLP ingest** (HTTP `POST /v1/metrics`).

## What “receiver in Nix” means here

OpenTelemetry **receivers** are compiled into `otelcontribcol` (Go). You do not implement a receiver *in* the Nix language. Instead, Nix is used to **declare** the collector configuration: in this flake, `pkgs.formats.yaml` generates `otel-collector.yaml`, including the `receivers.prometheus` block and its `scrape_configs`. That keeps scrape intervals, targets, and relabeling in versionable, typed-ish Nix data instead of hand-edited YAML.

If you need behavior that no stock receiver provides, you extend the collector in Go (custom receiver) and package that binary with Nix—still not a Nix implementation of the receiver logic.

## Flow

1. **filer-mock** — `GET http://127.0.0.1:9333/metrics` returns Prometheus exposition format (includes a `seaweed_filer_*`-style series name for illustration).
2. **otelcontribcol** — `prometheus` receiver scrapes that target; `batch` (1s timeout) then mirrors each batch to **`debug`** (`verbosity: detailed`, full series on stdout) and **`otlphttp`**. Collector **log level is `debug`** (`service.telemetry.logs`) so scrape/discovery lines from the Prometheus receiver appear in the same stream.
3. **grafana-mock** — listens on `4318` and logs each OTLP payload size (protobuf body as shipped by the exporter).

## Run

From this directory:

```bash
nix run .
```

You should see `[grafana-mock]` lines with byte counts when the exporter POSTs OTLP, **`[filer-mock] GET /metrics`** when the receiver scrapes, **component `debug` lines** (`ResourceMetrics`, metric names) for each flushed batch (post-receiver, post-batch), and extra **Prometheus receiver** log lines from `service.telemetry.logs.level=debug`. Stop with Ctrl+C; subprocesses are torn down by the wrapper script.

If you see **address already in use**, something is still bound on **9333** or **4318** (often a previous demo). Run `lsof -nP -iTCP:9333 -sTCP:LISTEN` and `lsof -nP -iTCP:4318 -sTCP:LISTEN`, stop those PIDs, then run again. The wrapper now refuses to start if those ports are already listening.

The flake pins **nixos-unstable** (see `flake.lock`) so the collector binary tracks current nixpkgs (`otelcol-contrib`). If you ever see `No such file or directory` for the collector path under `/nix/store`, your substitute may be incomplete; run `nix store verify --repair` or delete the broken path after removing `result/` and rebuild.

First-time run downloads **OpenTelemetry Collector Contrib** (~300MB); mocks use Python’s stdlib only.

## Ports

| Service        | Port |
|----------------|------|
| Filer `/metrics` | 9333 |
| OTLP HTTP sink | 4318 |

## Files

| File        | Role |
|-------------|------|
| `flake.nix` | Generates OTEL YAML, wraps `otelcontribcol` + mocks |
| `demo.py`   | `filer` and `sink` subcommands |

## Pointing at a real Seaweed filer

Replace the scrape target in `flake.nix` (`static_configs.targets`) with your filer’s host:port (same `/metrics` path Seaweed exposes). Re-run `nix run .`; no code changes outside that config.

## Pointing at real Grafana OTLP

Set `exporters.otlphttp.endpoint` to your Grafana OTLP endpoint and add headers (API keys) per Grafana docs—still declarative in the same generated YAML.

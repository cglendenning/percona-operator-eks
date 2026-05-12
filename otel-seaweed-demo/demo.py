#!/usr/bin/env python3
"""
Minimal stand-ins for local demos:
  filer  — serves Prometheus exposition format on GET /metrics
  sink   — accepts OTLP/HTTP POST /v1/metrics (what Grafana Cloud OTLP ingest expects)
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer


class FilerMetrics(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = """# HELP seaweed_filer_request_counter Mock SeaweedFS-style request counter.
# TYPE seaweed_filer_request_counter counter
seaweed_filer_request_counter{host="mock-filer"} 42
# HELP go_goroutines Number of goroutines (placeholder series).
# TYPE go_goroutines gauge
go_goroutines 17
""".encode(
            "utf-8"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"[filer-mock] {args[0] if args else fmt}", flush=True)


class OtelSink(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        if self.path not in ("/v1/metrics", "/v1/metrics/"):
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length", 0))
        _data = self.rfile.read(n)
        ctype = self.headers.get("Content-Type", "")
        print(
            f"[grafana-mock] OTLP/HTTP {self.path} bytes={n} content-type={ctype!r}",
            flush=True,
        )
        self.send_response(200)
        self.end_headers()

    def log_message(self, fmt: str, *args: object) -> None:
        pass


def main() -> None:
    p = argparse.ArgumentParser(description="Seaweed filer + Grafana OTLP sink mocks")
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("filer", help="Prometheus /metrics on HTTP")
    f.add_argument("--host", default="127.0.0.1")
    f.add_argument("--port", type=int, default=9333)
    s = sub.add_parser("sink", help="OTLP HTTP /v1/metrics listener")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=4318)
    args = p.parse_args()
    if args.cmd == "filer":
        httpd = HTTPServer((args.host, args.port), FilerMetrics)
        print(
            f"[filer-mock] Prometheus text: http://{args.host}:{args.port}/metrics",
            flush=True,
        )
        httpd.serve_forever()
    else:
        httpd = HTTPServer((args.host, args.port), OtelSink)
        print(
            f"[grafana-mock] OTLP/HTTP listening (expect POST /v1/metrics) on http://{args.host}:{args.port}",
            flush=True,
        )
        httpd.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Serves data_platform_capabilities/static files (index.html + capabilities.json) over HTTP.
# Default port 8765 matches the previous standalone workspace location.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/data_platform_capabilities"
PORT="${PORT:-8765}"
exec python3 -m http.server "$PORT"

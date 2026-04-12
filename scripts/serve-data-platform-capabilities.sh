#!/usr/bin/env bash
# Serves data_platform_capabilities (index.html + capabilities.json) over HTTP.
# Default port 8765 matches the previous standalone workspace location.
#
# WSL (Windows): run from bash inside WSL (repo may live under /home/... or /mnt/c/...):
#   ./scripts/serve-data-platform-capabilities.sh
#   bash scripts/serve-data-platform-capabilities.sh
# If the file has CRLF line endings you may see "bad interpreter" or "$'\r'"; fix with:
#   sed -i 's/\r$//' scripts/serve-data-platform-capabilities.sh
#
# Open in the Windows browser: http://127.0.0.1:$PORT (WSL2 forwards localhost).
#
# Environment: PORT (default 8765), BIND (default 0.0.0.0; use 127.0.0.1 to restrict).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/data_platform_capabilities"

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "serve-data-platform-capabilities: need python3 or python on PATH" >&2
  exit 1
fi

PORT="${PORT:-8765}"
BIND="${BIND:-0.0.0.0}"

# --bind: listen on all interfaces; works with WSL2 localhost forwarding from Windows.
# Requires Python 3.4+ (standard on current WSL images).
exec "$PY" -m http.server "$PORT" --bind "$BIND"

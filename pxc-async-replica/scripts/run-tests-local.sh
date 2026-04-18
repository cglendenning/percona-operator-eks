#!/usr/bin/env bash
# Run unit tests locally (Linux / WSL / macOS). Requires Node.js 20+.
# Unit tests intentionally avoid loading @kubernetes/client-node (ESM/CJS issues on some Linux Node builds).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
npm run build
exec node --test \
  dist/primitives.test.js \
  dist/channel-normalize.test.js \
  dist/restore.test.js \
  dist/replication-health.test.js \
  dist/mysql.test.js \
  dist/wait-until.test.js \
  dist/pxc-cluster-ready.test.js \
  dist/transient-errors.test.js

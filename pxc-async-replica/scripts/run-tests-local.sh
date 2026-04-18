#!/usr/bin/env bash
# Run unit tests locally (Linux / WSL / macOS). Requires Node.js 20+.
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
  dist/replication-cluster.test.js

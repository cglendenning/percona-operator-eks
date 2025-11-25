#!/bin/bash

# Quick development startup (no build step)

set -e

echo "🚨 Starting DR Dashboard (dev mode)..."

# Get the directory of this script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Set default port if not specified
PORT="${PORT:-8080}"

echo "🚀 Starting server on port $PORT..."
echo "📍 Open http://localhost:$PORT in your browser"
echo ""

PORT=$PORT go run main.go

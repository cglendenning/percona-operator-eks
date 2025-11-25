#!/bin/bash

# Disaster Recovery Dashboard Startup Script
# Works on both macOS and Linux (including WSL)

set -e

echo "🚨 Starting Disaster Recovery Dashboard..."

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "❌ Error: Go is not installed. Please install Go 1.21 or later."
    exit 1
fi

# Get the directory of this script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Check if disaster scenarios exist
if [ ! -f "../testing/eks/disaster_scenarios/disaster_scenarios.json" ]; then
    echo "⚠️  Warning: EKS disaster scenarios not found at ../testing/eks/disaster_scenarios/disaster_scenarios.json"
fi

if [ ! -f "../testing/on-prem/disaster_scenarios/disaster_scenarios.json" ]; then
    echo "⚠️  Warning: On-prem disaster scenarios not found at ../testing/on-prem/disaster_scenarios/disaster_scenarios.json"
fi

# Set default port if not specified
PORT="${PORT:-8080}"

echo "📦 Downloading dependencies..."
go mod download

echo "🔨 Building application..."
go build -o dr-dashboard-bin main.go

echo "✅ Build complete!"
echo "🚀 Starting server on port $PORT..."
echo "📍 Open http://localhost:$PORT in your browser"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

PORT=$PORT ./dr-dashboard-bin

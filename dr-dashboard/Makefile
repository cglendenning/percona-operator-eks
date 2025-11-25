# DR Dashboard Makefile

.PHONY: help build run dev clean test

help: ## Show this help message
	@echo "DR Dashboard - Make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build the application binary
	@echo "🔨 Building dr-dashboard..."
	@go build -o dr-dashboard main.go
	@echo "✅ Build complete: ./dr-dashboard"

run: build ## Build and run the application
	@echo "🚀 Starting DR Dashboard on port 8080..."
	@./dr-dashboard

dev: ## Run in development mode (no build)
	@echo "🚀 Starting DR Dashboard (dev mode)..."
	@go run main.go

clean: ## Clean build artifacts
	@echo "🧹 Cleaning build artifacts..."
	@rm -f dr-dashboard dr-dashboard-bin
	@echo "✅ Clean complete"

test: ## Run Go tests
	@echo "🧪 Running tests..."
	@go test -v ./...

check: ## Verify scenarios can be loaded
	@echo "🔍 Checking disaster scenarios..."
	@test -f ../testing/eks/disaster_scenarios/disaster_scenarios.json || (echo "❌ EKS scenarios not found"; exit 1)
	@test -f ../testing/on-prem/disaster_scenarios/disaster_scenarios.json || (echo "❌ On-prem scenarios not found"; exit 1)
	@echo "✅ All scenario files found"

fmt: ## Format Go code
	@echo "🎨 Formatting code..."
	@go fmt ./...
	@echo "✅ Format complete"

lint: ## Lint Go code (requires golangci-lint)
	@echo "🔍 Linting code..."
	@golangci-lint run || echo "⚠️  Install golangci-lint: https://golangci-lint.run/usage/install/"

deps: ## Download dependencies
	@echo "📦 Downloading dependencies..."
	@go mod download
	@echo "✅ Dependencies downloaded"

tidy: ## Tidy go.mod
	@echo "🧹 Tidying go.mod..."
	@go mod tidy
	@echo "✅ Tidy complete"

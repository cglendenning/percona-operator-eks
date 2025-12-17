# DR Dashboard Manifest Generation
#
# Usage:
#   make render                    # Generate manifests.yaml
#   make render REGISTRY=ghcr.io/myorg TAG=v1.0.0
#   make deploy                    # Apply to cluster
#   make clean                     # Remove generated files

REGISTRY ?=
TAG ?= latest
NAMESPACE ?= default
SERVICE_TYPE ?= ClusterIP

.PHONY: render deploy clean help

help:
	@echo "DR Dashboard Manifest Generation"
	@echo ""
	@echo "Targets:"
	@echo "  render   - Generate manifests.yaml"
	@echo "  deploy   - Apply manifests to cluster"
	@echo "  clean    - Remove generated files"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY      Container registry (default: local)"
	@echo "  TAG           Image tag (default: latest)"
	@echo "  NAMESPACE     K8s namespace (default: default)"
	@echo "  SERVICE_TYPE  ClusterIP, NodePort, LoadBalancer (default: ClusterIP)"
	@echo ""
	@echo "Examples:"
	@echo "  make render REGISTRY=ghcr.io/myorg TAG=v1.0.0"
	@echo "  make deploy NAMESPACE=dr-dashboard"

render:
	@nix build .#default --out-link result
	@cp result/manifests.yaml manifests.yaml
	@echo "Generated manifests.yaml"

deploy: render
	kubectl apply -f manifests.yaml

clean:
	rm -f manifests.yaml result result-*


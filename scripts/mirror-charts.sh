#!/bin/bash

# Chart Mirroring Script
# This script downloads charts from external repositories and uploads them to ChartMuseum

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
CHARTMUSEUM_URL="${CHARTMUSEUM_URL:-http://chartmuseum.chartmuseum.svc.cluster.local:8080}"
REPO_NAME="${REPO_NAME:-internal}"
TEMP_DIR="${TEMP_DIR:-/tmp/chart-mirror-$(date +%s)}"

# Check prerequisites
check_prerequisites() {
    command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed. Aborting."; exit 1; }
    
    # Check if helm-push plugin is installed
    if ! helm plugin list | grep -q cm-push; then
        log_info "Installing helm-push plugin..."
        helm plugin install https://github.com/chartmuseum/helm-push.git || {
            log_error "Failed to install helm-push plugin"
            exit 1
        }
    fi
}

# Function to mirror a chart
mirror_chart() {
    local repo_name=$1
    local repo_url=$2
    local chart_name=$3
    local chart_version="${4:-}"  # Optional version
    
    log_info "Mirroring ${repo_name}/${chart_name}${chart_version:+ (version: ${chart_version})}..."
    
    # Add external repo if not exists
    if ! helm repo list | grep -q "^${repo_name}"; then
        log_info "Adding external repo: ${repo_name}"
        helm repo add "${repo_name}" "${repo_url}" || {
            log_error "Failed to add repo ${repo_name}"
            return 1
        }
    fi
    
    # Update repos
    helm repo update "${repo_name}"
    
    # Pull chart
    log_info "Downloading chart..."
    if [ -n "$chart_version" ]; then
        helm pull "${repo_name}/${chart_name}" --version "${chart_version}" || {
            log_error "Failed to pull chart ${chart_name} version ${chart_version}"
            return 1
        }
    else
        helm pull "${repo_name}/${chart_name}" || {
            log_error "Failed to pull chart ${chart_name}"
            return 1
        }
    fi
    
    # Push to ChartMuseum
    log_info "Uploading to ChartMuseum..."
    for chart_file in "${chart_name}"*.tgz; do
        if [ -f "$chart_file" ]; then
            helm cm-push "$chart_file" "${REPO_NAME}" || {
                log_warn "Failed to push ${chart_file} (may already exist)"
            }
            rm -f "$chart_file"
        fi
    done
    
    log_info "✓ Successfully mirrored ${chart_name}"
}

# Main mirroring function
mirror_all_charts() {
    log_info "Starting chart mirroring process..."
    log_info "ChartMuseum URL: ${CHARTMUSEUM_URL}"
    log_info "Temporary directory: ${TEMP_DIR}"
    
    # Create temp directory
    mkdir -p "${TEMP_DIR}"
    cd "${TEMP_DIR}"
    
    # Add internal repo (ChartMuseum)
    log_info "Adding ChartMuseum repo..."
    if helm repo add "${REPO_NAME}" "${CHARTMUSEUM_URL}" 2>/dev/null; then
        log_info "✓ Added ChartMuseum repo: ${REPO_NAME}"
    else
        # Check if repo already exists
        if helm repo list | grep -q "^${REPO_NAME}"; then
            log_info "ChartMuseum repo ${REPO_NAME} already exists"
        else
            log_error "Failed to add ChartMuseum repo"
            exit 1
        fi
    fi
    
    # Update all repos
    log_info "Updating Helm repositories..."
    helm repo update
    
    # Mirror Percona charts
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Mirroring Percona Charts"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mirror_chart "percona" "https://percona.github.io/percona-helm-charts/" "pxc-operator"
    mirror_chart "percona" "https://percona.github.io/percona-helm-charts/" "pxc-db"
    
    # Mirror MinIO chart
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Mirroring MinIO Charts"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mirror_chart "minio" "https://charts.min.io/" "minio"
    
    # Mirror LitmusChaos chart
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Mirroring LitmusChaos Charts"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mirror_chart "litmuschaos" "https://litmuschaos.github.io/litmus-helm/" "litmus"
    
    # Cleanup
    cd -
    rm -rf "${TEMP_DIR}"
    
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Chart Mirroring Complete!"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "To verify, run:"
    log_info "  helm search repo ${REPO_NAME}"
    log_info ""
}

# Main execution
main() {
    check_prerequisites
    mirror_all_charts
}

# Run main function
main "$@"


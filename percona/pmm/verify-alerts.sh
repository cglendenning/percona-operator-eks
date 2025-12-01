#!/bin/bash
#
# PMM Alert Verification Script
# 
# Run this after deploying PMM via Fleet to verify that custom alerts
# are properly loaded and visible in the PMM UI.
#
# Usage:
#   ./verify-alerts.sh [--namespace pmm] [--kubeconfig /path/to/config]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="${NAMESPACE:-pmm}"
KUBECONFIG_FLAG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG_FLAG="--kubeconfig=$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--namespace pmm] [--kubeconfig /path/to/config]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# kubectl wrapper
kctl() {
    kubectl $KUBECONFIG_FLAG "$@"
}

# Logging functions
log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
    echo -e "  $1"
}

# Track overall status
ERRORS=0
WARNINGS=0

# Check 1: ConfigMaps exist
log_section "Step 1: Checking ConfigMaps"

if kctl get cm pmm-alert-rules -n "$NAMESPACE" &>/dev/null; then
    log_success "ConfigMap 'pmm-alert-rules' exists"
else
    log_error "ConfigMap 'pmm-alert-rules' NOT FOUND"
    log_info "Run: kubectl apply -f percona/pmm/pmm-alerts.yaml"
    ERRORS=$((ERRORS + 1))
fi

if kctl get cm pmm-alertmanager-config -n "$NAMESPACE" &>/dev/null; then
    log_success "ConfigMap 'pmm-alertmanager-config' exists"
else
    log_error "ConfigMap 'pmm-alertmanager-config' NOT FOUND"
    log_info "Run: kubectl apply -f percona/pmm/pmm-notifications.yaml"
    ERRORS=$((ERRORS + 1))
fi

# Check 2: PMM pod exists and is running
log_section "Step 2: Checking PMM Pod Status"

POD_NAME=$(kctl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=pmm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    # Try alternative label
    POD_NAME=$(kctl get pods -n "$NAMESPACE" -l app=pmm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "$POD_NAME" ]; then
    log_error "PMM pod not found in namespace '$NAMESPACE'"
    log_info "Check if PMM is deployed: kubectl get pods -n $NAMESPACE"
    ERRORS=$((ERRORS + 1))
    exit 1
else
    log_success "PMM pod found: $POD_NAME"
    
    POD_STATUS=$(kctl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [ "$POD_STATUS" = "Running" ]; then
        log_success "Pod status: $POD_STATUS"
    else
        log_warn "Pod status: $POD_STATUS (expected: Running)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Check 3: Volumes are mounted
log_section "Step 3: Checking Volume Mounts"

VOLUMES=$(kctl get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.volumes[] | select(.configMap.name == "pmm-alert-rules" or .configMap.name == "pmm-alertmanager-config") | .name' 2>/dev/null || echo "")

if echo "$VOLUMES" | grep -q "custom-alert-rules"; then
    log_success "Volume 'custom-alert-rules' is configured"
else
    log_error "Volume 'custom-alert-rules' NOT mounted"
    log_info "Update values/pmm-base.yaml with extraVolumes configuration"
    ERRORS=$((ERRORS + 1))
fi

if echo "$VOLUMES" | grep -q "custom-alertmanager-config"; then
    log_success "Volume 'custom-alertmanager-config' is configured"
else
    log_warn "Volume 'custom-alertmanager-config' NOT mounted"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 4: Volume mounts in container
log_section "Step 4: Checking Container Volume Mounts"

MOUNTS=$(kctl get pod "$POD_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.containers[0].volumeMounts[] | select(.name == "custom-alert-rules" or .name == "custom-alertmanager-config") | "\(.name):\(.mountPath)"' 2>/dev/null || echo "")

if [ -n "$MOUNTS" ]; then
    log_success "Volume mounts configured:"
    echo "$MOUNTS" | while read -r mount; do
        log_info "$mount"
    done
else
    log_error "No volume mounts found in container"
    log_info "Update values/pmm-base.yaml with extraVolumeMounts configuration"
    ERRORS=$((ERRORS + 1))
fi

# Check 5: Find correct Grafana provisioning path
log_section "Step 5: Finding Grafana Provisioning Directory"

POSSIBLE_PATHS=(
    "/srv/grafana/provisioning/alerting"
    "/etc/grafana/provisioning/alerting"
    "/usr/share/grafana/conf/provisioning/alerting"
    "/var/lib/grafana/provisioning/alerting"
)

FOUND_PATH=""
for path in "${POSSIBLE_PATHS[@]}"; do
    if kctl exec -n "$NAMESPACE" "$POD_NAME" -- ls "$path" &>/dev/null; then
        FOUND_PATH="$path"
        log_success "Found Grafana provisioning path: $FOUND_PATH"
        break
    fi
done

if [ -z "$FOUND_PATH" ]; then
    log_warn "Could not find standard Grafana provisioning path"
    log_info "Checking all provisioning directories..."
    
    kctl exec -n "$NAMESPACE" "$POD_NAME" -- find / -type d -name "provisioning" 2>/dev/null | head -5 | while read -r dir; do
        log_info "Found: $dir"
    done
    WARNINGS=$((WARNINGS + 1))
fi

# Check 6: Verify alert files exist in pod
log_section "Step 6: Checking Alert Files in Pod"

if [ -n "$FOUND_PATH" ]; then
    ALERT_FILES=$(kctl exec -n "$NAMESPACE" "$POD_NAME" -- ls -la "$FOUND_PATH" 2>/dev/null || echo "")
    
    if echo "$ALERT_FILES" | grep -q "mysql-alerts.yaml"; then
        log_success "Alert file 'mysql-alerts.yaml' found in provisioning directory"
        
        # Show a snippet of the file
        log_info "Alert file content preview:"
        kctl exec -n "$NAMESPACE" "$POD_NAME" -- cat "$FOUND_PATH/mysql-alerts.yaml" 2>/dev/null | head -10 | while read -r line; do
            echo "    $line"
        done
    else
        log_error "Alert file NOT found in $FOUND_PATH"
        log_info "Available files:"
        echo "$ALERT_FILES" | while read -r line; do
            log_info "$line"
        done
        ERRORS=$((ERRORS + 1))
    fi
fi

# Check 7: Query Prometheus for alert rules
log_section "Step 7: Checking Prometheus Alert Rules"

PROMETHEUS_RULES=$(kctl exec -n "$NAMESPACE" "$POD_NAME" -- curl -s 'http://localhost:9090/api/v1/rules' 2>/dev/null || echo "")

if echo "$PROMETHEUS_RULES" | jq -e '.data.groups[] | select(.name == "mysql_disk_usage")' &>/dev/null; then
    log_success "Alert group 'mysql_disk_usage' loaded in Prometheus"
    
    ALERT_COUNT=$(echo "$PROMETHEUS_RULES" | jq -r '.data.groups[] | select(.name == "mysql_disk_usage") | .rules | length')
    log_info "Found $ALERT_COUNT alert rule(s) in group"
    
    # List alert names
    echo "$PROMETHEUS_RULES" | jq -r '.data.groups[] | select(.name == "mysql_disk_usage") | .rules[] | .name' | while read -r alert_name; do
        log_success "  Alert: $alert_name"
    done
else
    log_error "Alert group 'mysql_disk_usage' NOT loaded in Prometheus"
    log_info "Check Grafana logs: kubectl logs -n $NAMESPACE $POD_NAME | grep provisioning"
    ERRORS=$((ERRORS + 1))
fi

# Check 8: Verify Alertmanager config
log_section "Step 8: Checking Alertmanager Configuration"

ALERTMANAGER_STATUS=$(kctl exec -n "$NAMESPACE" "$POD_NAME" -- curl -s 'http://localhost:9093/api/v1/status' 2>/dev/null || echo "")

if echo "$ALERTMANAGER_STATUS" | jq -e '.data.config' &>/dev/null; then
    log_success "Alertmanager is running and has configuration"
    
    # Check for PagerDuty receiver
    if echo "$ALERTMANAGER_STATUS" | jq -e '.data.config.receivers[] | select(.name | contains("pagerduty"))' &>/dev/null; then
        log_success "PagerDuty receiver configured"
    else
        log_warn "PagerDuty receiver not found in Alertmanager config"
        log_info "Check pmm-notifications.yaml configuration"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    log_warn "Could not retrieve Alertmanager configuration"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 9: Test alert query
log_section "Step 9: Testing Alert Query"

TEST_QUERY="(1 - (node_filesystem_avail_bytes{mountpoint=~\"/var/lib/mysql|/data|/mysql-data\"} / node_filesystem_size_bytes{mountpoint=~\"/var/lib/mysql|/data|/mysql-data\"})) * 100"
QUERY_RESULT=$(kctl exec -n "$NAMESPACE" "$POD_NAME" -- curl -s --data-urlencode "query=$TEST_QUERY" 'http://localhost:9090/api/v1/query' 2>/dev/null || echo "")

if echo "$QUERY_RESULT" | jq -e '.data.result | length > 0' &>/dev/null; then
    RESULT_COUNT=$(echo "$QUERY_RESULT" | jq -r '.data.result | length')
    log_success "Alert query returned $RESULT_COUNT metric(s)"
    
    # Show current disk usage values
    echo "$QUERY_RESULT" | jq -r '.data.result[] | "\(.metric.instance): \(.value[1])%"' | head -3 | while read -r instance_value; do
        log_info "$instance_value"
    done
else
    log_warn "Alert query returned no results"
    log_info "This is normal if no MySQL hosts are monitored yet"
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
log_section "Verification Summary"

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    log_success "ALL CHECKS PASSED! Alerts are properly configured."
    echo ""
    echo -e "${GREEN}Your alerts should be visible in PMM UI:${NC}"
    echo "  1. Navigate to PMM → Alerting → Alert rules"
    echo "  2. Search for 'MySQLDiskUsage'"
    echo "  3. You should see:"
    echo "     - MySQLDiskUsageHigh (warning)"
    echo "     - MySQLDiskUsageCritical (critical)"
    echo ""
elif [ $ERRORS -eq 0 ]; then
    log_warn "Checks passed with $WARNINGS warning(s)"
    echo ""
    echo "Alerts should work, but review warnings above."
else
    log_error "Found $ERRORS error(s) and $WARNINGS warning(s)"
    echo ""
    echo -e "${RED}TROUBLESHOOTING STEPS:${NC}"
    echo "1. Check ConfigMaps are applied:"
    echo "   kubectl get cm -n $NAMESPACE pmm-alert-rules pmm-alertmanager-config"
    echo ""
    echo "2. Verify volume mounts in values/pmm-base.yaml:"
    echo "   - extraVolumes should reference ConfigMaps"
    echo "   - extraVolumeMounts should mount to correct path"
    echo ""
    echo "3. Restart PMM to reload configuration:"
    echo "   kubectl rollout restart deployment pmm-server -n $NAMESPACE"
    echo ""
    echo "4. Check Grafana logs for errors:"
    echo "   kubectl logs -n $NAMESPACE $POD_NAME | grep -i 'provisioning\\|alert\\|error'"
    echo ""
fi

exit $ERRORS

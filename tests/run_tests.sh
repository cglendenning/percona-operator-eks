#!/bin/bash
set -euo pipefail

# Test runner script for Percona XtraDB Cluster tests
# Can be run manually on Mac or in GitLab CI

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Percona XtraDB Cluster Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check prerequisites
echo -e "${BLUE}Checking prerequisites...${NC}"

command -v python3 >/dev/null 2>&1 || { echo -e "${RED}✗ python3 not found${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}✗ kubectl not found${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}✗ helm not found${NC}" >&2; exit 1; }

# Check Kubernetes connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${RED}✗ Cannot connect to Kubernetes cluster${NC}" >&2
    echo "Please configure kubectl to connect to your cluster"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites met${NC}"
echo ""

# Install/update Python dependencies
echo -e "${BLUE}Installing Python dependencies...${NC}"
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

source venv/bin/activate
pip install --upgrade pip >/dev/null 2>&1
pip install -q -r tests/requirements.txt

echo -e "${GREEN}✓ Dependencies installed${NC}"
echo ""

# Set default environment variables if not set
export TEST_NAMESPACE=${TEST_NAMESPACE:-percona}
export TEST_CLUSTER_NAME=${TEST_CLUSTER_NAME:-pxc-cluster}
export TEST_BACKUP_TYPE=${TEST_BACKUP_TYPE:-minio}
export TEST_BACKUP_BUCKET=${TEST_BACKUP_BUCKET:-percona-backups}
export TEST_OPERATOR_NAMESPACE=${TEST_OPERATOR_NAMESPACE:-$TEST_NAMESPACE}

# Auto-detect node count from cluster if not set
if [ -z "${TEST_EXPECTED_NODES:-}" ]; then
    # Try to get node count from PXC StatefulSet
    # First try to find by name pattern (contains -pxc but not proxysql)
    PXC_STS_NAME=$(kubectl get statefulset -n "$TEST_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '\-pxc' | grep -v proxysql | head -1)
    if [ -n "$PXC_STS_NAME" ]; then
        PXC_STS=$(kubectl get statefulset "$PXC_STS_NAME" -n "$TEST_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ -n "$PXC_STS" ] && [ "$PXC_STS" != "null" ] && [ "$PXC_STS" -gt 0 ] 2>/dev/null; then
            export TEST_EXPECTED_NODES=$PXC_STS
            echo -e "${BLUE}Auto-detected node count: ${GREEN}$TEST_EXPECTED_NODES${NC} (from PXC StatefulSet: $PXC_STS_NAME)"
        fi
    fi
    
    # If auto-detection failed, use default
    if [ -z "${TEST_EXPECTED_NODES:-}" ]; then
        export TEST_EXPECTED_NODES=6
        echo -e "${YELLOW}⚠ Could not auto-detect node count, using default: 6${NC}"
        echo -e "${YELLOW}   Set TEST_EXPECTED_NODES environment variable to override${NC}"
    fi
fi

echo -e "${BLUE}Test Configuration:${NC}"
echo "  Namespace: $TEST_NAMESPACE"
echo "  Cluster Name: $TEST_CLUSTER_NAME"
echo "  Expected Nodes: $TEST_EXPECTED_NODES"
echo "  Backup Type: $TEST_BACKUP_TYPE"
if [ -n "$TEST_BACKUP_BUCKET" ]; then
    echo "  Backup Bucket: $TEST_BACKUP_BUCKET"
fi
echo ""

# Check if namespace exists
if ! kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: Namespace '$TEST_NAMESPACE' does not exist${NC}"
    echo "Some tests may fail. Create the namespace and deploy Percona cluster first."
    echo ""
fi

# Run tests
echo -e "${BLUE}Running tests...${NC}"
echo ""

# Determine pytest options
PYTEST_OPTS=(
    "-v"
    "--tb=short"
    "--color=yes"
    "tests/"
)

# Add HTML report if requested
if [ "${GENERATE_HTML_REPORT:-}" == "true" ]; then
    PYTEST_OPTS+=("--html=tests/report.html" "--self-contained-html")
fi

# Add coverage if requested
if [ "${GENERATE_COVERAGE:-}" == "true" ]; then
    PYTEST_OPTS+=("--cov=tests" "--cov-report=term-missing")
fi

# Run pytest
set +e
pytest "${PYTEST_OPTS[@]}"
TEST_RESULT=$?
set -e

echo ""
echo -e "${BLUE}========================================${NC}"
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed! ✓${NC}"
else
    echo -e "${RED}Some tests failed ✗${NC}"
fi
echo -e "${BLUE}========================================${NC}"
if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo -e "${BLUE}Note: Warnings are suppressed by default.${NC}"
    echo -e "${BLUE}      To view warnings, run: pytest -W default tests/${NC}"
fi

if [ "${GENERATE_HTML_REPORT:-}" == "true" ]; then
    echo ""
    echo -e "${GREEN}HTML report generated: tests/report.html${NC}"
fi

exit $TEST_RESULT


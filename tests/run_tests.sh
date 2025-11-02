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

# Function to display usage information (defined early so it can be used before setup)
show_usage() {
    echo -e "${BLUE}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${BLUE}Description:${NC}"
    echo "  Run Percona XtraDB Cluster test suite. By default, runs all test categories"
    echo "  (unit, integration, and resiliency tests with chaos experiments)."
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo -e "  ${GREEN}-h, --help${NC}"
    echo "      Show this help message and exit"
    echo ""
    echo -e "  ${GREEN}--show-warnings${NC}"
    echo "      Display Python warnings during test execution (default: suppressed)"
    echo ""
    echo -e "  ${GREEN}--no-resiliency-tests${NC}"
    echo "      Exclude resiliency tests from execution (also skips chaos experiments)"
    echo ""
    echo -e "  ${GREEN}--no-unit-tests${NC}"
    echo "      Exclude unit tests from execution"
    echo ""
    echo -e "  ${GREEN}--no-integration-tests${NC}"
    echo "      Exclude integration tests from execution"
    echo ""
    echo -e "  ${GREEN}--run-resiliency-tests${NC}"
    echo "      [Legacy flag] Explicitly run resiliency tests (now included by default)"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  # Run all tests (unit, integration, resiliency with chaos)"
    echo "  $0"
    echo ""
    echo "  # Run only unit and integration tests"
    echo "  $0 --no-resiliency-tests"
    echo ""
    echo "  # Run only resiliency tests with chaos"
    echo "  $0 --no-unit-tests --no-integration-tests"
    echo ""
    echo "  # Run all tests and show warnings"
    echo "  $0 --show-warnings"
    echo ""
    echo "  # Run only integration tests"
    echo "  $0 --no-unit-tests --no-resiliency-tests"
    echo ""
    echo -e "${BLUE}Environment Variables:${NC}"
    echo "  TEST_NAMESPACE          Kubernetes namespace (default: percona)"
    echo "  TEST_CLUSTER_NAME       Percona cluster name (default: pxc-cluster)"
    echo "  TEST_EXPECTED_NODES     Expected number of PXC nodes (default: auto-detected)"
    echo "  TEST_BACKUP_TYPE        Backup type: minio or s3 (default: minio)"
    echo "  TEST_BACKUP_BUCKET      Backup bucket name (default: percona-backups)"
    echo "  RESILIENCY_MTTR_TIMEOUT_SECONDS  MTTR timeout for resiliency tests (default: 120)"
    echo "  GENERATE_HTML_REPORT    Set to 'true' to generate HTML test report"
    echo "  GENERATE_COVERAGE       Set to 'true' to generate coverage report"
    echo ""
}

# Check for help flag immediately (before any setup work)
for arg in "$@"; do
    case $arg in
        -h|--help)
            show_usage
            exit 0
            ;;
    esac
done

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

# Prefer Python 3.12+ for OpenSSL 3.x support (required for urllib3 2.5.0+)
PYTHON_CMD="python3"
if command -v python3.12 >/dev/null 2>&1; then
    PYTHON_CMD="python3.12"
    echo -e "${BLUE}Using Python 3.12 for OpenSSL 3.x support${NC}"
elif command -v python3.11 >/dev/null 2>&1; then
    PYTHON_CMD="python3.11"
    echo -e "${BLUE}Using Python 3.11${NC}"
fi

# Check if venv exists and was created with the right Python version
RECREATE_VENV=false
if [ -d "venv" ]; then
    if [ -f "venv/bin/python" ]; then
        VENV_PYTHON_VERSION=$("venv/bin/python" --version 2>&1 | grep -oE "[0-9]+\.[0-9]+" | head -1)
        TARGET_VERSION=$($PYTHON_CMD --version 2>&1 | grep -oE "[0-9]+\.[0-9]+" | head -1)
        # Recreate venv if Python version doesn't match or is < 3.11
        if [ "$VENV_PYTHON_VERSION" != "$TARGET_VERSION" ] || [ "${VENV_PYTHON_VERSION%.*}" -lt 3 ] || [ "${VENV_PYTHON_VERSION#*.}" -lt 11 ]; then
            echo -e "${YELLOW}⚠ Existing venv uses Python ${VENV_PYTHON_VERSION}, recreating with ${TARGET_VERSION}${NC}"
            RECREATE_VENV=true
        fi
    else
        RECREATE_VENV=true
    fi
else
    RECREATE_VENV=true
fi

if [ "$RECREATE_VENV" == "true" ]; then
    if [ -d "venv" ]; then
        rm -rf venv
    fi
    $PYTHON_CMD -m venv venv
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

# Parse command-line arguments
SHOW_WARNINGS=false
NO_RESILIENCY=false
NO_UNIT=false
NO_INTEGRATION=false
EXPLICIT_FLAGS=false

for arg in "$@"; do
    case $arg in
        --show-warnings)
            SHOW_WARNINGS=true
            EXPLICIT_FLAGS=true
            shift
            ;;
        --run-resiliency-tests)
            # Legacy flag - kept for backwards compatibility
            # Default behavior now runs all tests including resiliency
            EXPLICIT_FLAGS=true
            shift
            ;;
        --no-resiliency-tests)
            NO_RESILIENCY=true
            EXPLICIT_FLAGS=true
            shift
            ;;
        --no-unit-tests)
            NO_UNIT=true
            EXPLICIT_FLAGS=true
            shift
            ;;
        --no-integration-tests)
            NO_INTEGRATION=true
            EXPLICIT_FLAGS=true
            shift
            ;;
        *)
            # Unknown option - pass through to pytest if needed
            ;;
    esac
done

# Initialize pytest options
PYTEST_OPTS=(
    "-v"
    "-s"  # Disable output capturing so console.print works immediately
    "--tb=short"
    "--color=yes"
    "tests/"
)

# Default behavior: Run ALL tests (unit, integration, and resiliency)
# Only disable resiliency if explicitly excluded
if [ "$NO_RESILIENCY" == "false" ]; then
    export RUN_RESILIENCY_TESTS=true
    # Add pytest flag to trigger chaos experiments
    PYTEST_OPTS+=("--trigger-chaos")
fi

# Build pytest marker expression to exclude test categories
MARKER_EXPR=""
if [ "$NO_UNIT" == "true" ]; then
    MARKER_EXPR="${MARKER_EXPR}not unit"
fi
if [ "$NO_INTEGRATION" == "true" ]; then
    if [ -n "$MARKER_EXPR" ]; then
        MARKER_EXPR="${MARKER_EXPR} and not integration"
    else
        MARKER_EXPR="not integration"
    fi
fi
if [ "$NO_RESILIENCY" == "true" ]; then
    if [ -n "$MARKER_EXPR" ]; then
        MARKER_EXPR="${MARKER_EXPR} and not resiliency"
    else
        MARKER_EXPR="not resiliency"
    fi
fi

# Add marker expression to pytest options if any exclusions specified
if [ -n "$MARKER_EXPR" ]; then
    PYTEST_OPTS+=("-m" "$MARKER_EXPR")
fi

# Run tests
echo -e "${BLUE}Running tests...${NC}"

# Display test categories being run
if [ "$EXPLICIT_FLAGS" == "true" ]; then
    echo -e "${BLUE}Test categories:${NC}"
    if [ "$NO_UNIT" == "false" ]; then
        echo -e "  ${GREEN}✓${NC} Unit tests"
    else
        echo -e "  ${YELLOW}⊘${NC} Unit tests (excluded)"
    fi
    if [ "$NO_INTEGRATION" == "false" ]; then
        echo -e "  ${GREEN}✓${NC} Integration tests"
    else
        echo -e "  ${YELLOW}⊘${NC} Integration tests (excluded)"
    fi
    if [ "$NO_RESILIENCY" == "false" ]; then
        echo -e "  ${GREEN}✓${NC} Resiliency tests (with chaos)"
    else
        echo -e "  ${YELLOW}⊘${NC} Resiliency tests (excluded)"
    fi
else
    echo -e "${BLUE}Running all test categories (unit, integration, resiliency with chaos)${NC}"
fi
echo ""

# Add warning display if requested
if [ "$SHOW_WARNINGS" == "true" ]; then
    PYTEST_OPTS+=("-W" "default")
else
    PYTEST_OPTS+=("-W" "ignore")
fi

# Add HTML report if requested
if [ "${GENERATE_HTML_REPORT:-}" == "true" ]; then
    PYTEST_OPTS+=("--html=tests/report.html" "--self-contained-html")
fi

# Add coverage if requested
if [ "${GENERATE_COVERAGE:-}" == "true" ]; then
    PYTEST_OPTS+=("--cov=tests" "--cov-report=term-missing")
fi

# Run pytest and capture output
set +e
if [ "$SHOW_WARNINGS" == "true" ]; then
    # Show warnings directly
    pytest "${PYTEST_OPTS[@]}"
    TEST_RESULT=$?
    WARNING_COUNT=0
else
    # Run tests with warnings suppressed
    pytest "${PYTEST_OPTS[@]}"
    TEST_RESULT=$?
    
    # Count warnings by running again with warnings enabled (quietly, just to get count)
    # Replace -W ignore with -W default in the options
    WARNING_OPTS=()
    SKIP_NEXT=false
    for opt in "${PYTEST_OPTS[@]}"; do
        if [ "$SKIP_NEXT" == "true" ]; then
            SKIP_NEXT=false
            WARNING_OPTS+=("default")
        elif [ "$opt" == "-W" ]; then
            SKIP_NEXT=true
            WARNING_OPTS+=("-W")
        else
            WARNING_OPTS+=("$opt")
        fi
    done
    
    # Run quietly to get warning count from summary (suppress all visible output)
    WARNING_SUMMARY=$(pytest "${WARNING_OPTS[@]}" -q --tb=no 2>&1 | grep -oE "[0-9]+ warnings?" | grep -oE "[0-9]+" | head -1 || echo "0") 2>/dev/null
    if [ -n "$WARNING_SUMMARY" ] && [ "$WARNING_SUMMARY" -gt 0 ] 2>/dev/null; then
        WARNING_COUNT=$WARNING_SUMMARY
    else
        WARNING_COUNT=0
    fi
fi
set -e

echo ""
echo -e "${BLUE}========================================${NC}"
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed! ✓${NC}"
else
    echo -e "${RED}Some tests failed ✗${NC}"
fi
echo -e "${BLUE}========================================${NC}"

# Only show warning message if warnings were actually suppressed
if [ "$SHOW_WARNINGS" == "false" ] && [ "$WARNING_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${BLUE}$WARNING_COUNT warning(s) were suppressed.${NC}"
    echo -e "${BLUE}To see them, re-run with: ./tests/run_tests.sh --show-warnings${NC}"
fi

if [ "${GENERATE_HTML_REPORT:-}" == "true" ]; then
    echo ""
    echo -e "${GREEN}HTML report generated: tests/report.html${NC}"
fi

exit $TEST_RESULT


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
    echo -e "  ${GREEN}--no-dr-tests${NC}"
    echo "      Exclude disaster recovery scenario tests from execution"
    echo ""
    echo -e "  ${GREEN}--run-resiliency-tests${NC}"
    echo "      [Legacy flag] Explicitly run resiliency tests (now included by default)"
    echo ""
    echo -e "  ${GREEN}--verbose, -v${NC}"
    echo "      Show verbose output including setup, Python version, configuration, etc."
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  # Run all tests (unit, integration, resiliency, DR scenarios)"
    echo "  $0"
    echo ""
    echo "  # Run only unit and integration tests"
    echo "  $0 --no-resiliency-tests --no-dr-tests"
    echo ""
    echo "  # Run only resiliency tests with chaos"
    echo "  $0 --no-unit-tests --no-integration-tests"
    echo ""
    echo "  # Run only DR scenario tests"
    echo "  $0 --no-unit-tests --no-integration-tests --no-resiliency-tests"
    echo ""
    echo "  # Run all tests and show warnings"
    echo "  $0 --show-warnings"
    echo ""
    echo "  # Run only integration tests"
    echo "  $0 --no-unit-tests --no-resiliency-tests --no-dr-tests"
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

# Parse arguments for help and verbose flags (before any setup work)
VERBOSE=false
for arg in "$@"; do
    case $arg in
        -h|--help)
            show_usage
            exit 0
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
    esac
done

# Verbose output function
verbose_echo() {
    if [ "$VERBOSE" = "true" ]; then
        echo "$@"
    fi
}

# Always show header, but minimal
if [ "$VERBOSE" = "true" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Percona XtraDB Cluster Test Suite${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
fi

# Check prerequisites (always check, but only show output if verbose)
verbose_echo -e "${BLUE}Checking prerequisites...${NC}"

command -v python3 >/dev/null 2>&1 || { echo -e "${RED}✗ python3 not found${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}✗ kubectl not found${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}✗ helm not found${NC}" >&2; exit 1; }

# Check Kubernetes connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${RED}✗ Cannot connect to Kubernetes cluster${NC}" >&2
    echo "Please configure kubectl to connect to your cluster"
    exit 1
fi

verbose_echo -e "${GREEN}✓ Prerequisites met${NC}"
verbose_echo ""

# Install/update Python dependencies
verbose_echo -e "${BLUE}Installing Python dependencies...${NC}"

# Find and use the LATEST Python version available
PYTHON_CMD="python3"

# Check for latest Python versions in order: 3.14, 3.13, 3.12, 3.11
LATEST_VERSION=""
LATEST_CMD=""

for version in 3.14 3.13 3.12 3.11; do
    # Check in PATH first
    if command -v "python${version}" >/dev/null 2>&1 && "python${version}" --version >/dev/null 2>&1; then
        LATEST_CMD="python${version}"
        LATEST_VERSION="$version"
        break
    fi
    # Check Homebrew Cellar (common location for macOS)
    # Look for python3.X in bin directories under Cellar
    CELLAR_PYTHON=$(find /opt/homebrew/Cellar/python@${version} -path "*/bin/python${version}" -type f 2>/dev/null | sort -V | tail -1)
    if [ -n "$CELLAR_PYTHON" ] && [ -x "$CELLAR_PYTHON" ] && "$CELLAR_PYTHON" --version >/dev/null 2>&1; then
        LATEST_CMD="$CELLAR_PYTHON"
        LATEST_VERSION="$version"
        break
    fi
done

if [ -n "$LATEST_CMD" ]; then
    PYTHON_CMD="$LATEST_CMD"
    PYTHON_VERSION=$($PYTHON_CMD --version 2>&1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    verbose_echo -e "${BLUE}Using latest Python ${PYTHON_VERSION}${NC}"
else
    # Fallback to default python3
    PYTHON_VERSION=$(python3 --version 2>&1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    verbose_echo -e "${YELLOW}Using default python3 (${PYTHON_VERSION}) - consider installing Python 3.12+ for better OpenSSL support${NC}"
fi

# Remove ALL old virtual environments before creating a new one
verbose_echo -e "${BLUE}Cleaning up old virtual environments...${NC}"
find . -maxdepth 2 -type d \( -name "venv" -o -name "venv_*" -o -name ".venv*" \) ! -path "./.git/*" -exec rm -rf {} + 2>/dev/null || true

# Always recreate venv with the latest Python version (old venvs were already cleaned up above)
if [ ! -d "venv" ]; then
    verbose_echo -e "${BLUE}Creating new virtual environment with ${PYTHON_VERSION}...${NC}"
    $PYTHON_CMD -m venv venv
else
    # Double-check the venv is using the correct Python version
    VENV_PYTHON_VERSION=$("venv/bin/python" --version 2>&1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    if [ "$VENV_PYTHON_VERSION" != "$PYTHON_VERSION" ]; then
        verbose_echo -e "${YELLOW}⚠ Existing venv uses Python ${VENV_PYTHON_VERSION}, recreating with ${PYTHON_VERSION}${NC}"
        rm -rf venv
        $PYTHON_CMD -m venv venv
    else
        verbose_echo -e "${GREEN}✓ Virtual environment already exists with Python ${PYTHON_VERSION}${NC}"
    fi
fi

source venv/bin/activate
pip install --upgrade pip >/dev/null 2>&1
pip install -q -r tests/requirements.txt

verbose_echo -e "${GREEN}✓ Dependencies installed${NC}"
verbose_echo ""

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
        fi
    fi
    
    # If auto-detection failed, use default
    if [ -z "${TEST_EXPECTED_NODES:-}" ]; then
        export TEST_EXPECTED_NODES=6
        verbose_echo -e "${BLUE}Auto-detected node count: ${YELLOW}6${NC} (default - could not detect)"
    fi
else
    # Show detected node count even if not verbose
    verbose_echo -e "${BLUE}Auto-detected node count: ${GREEN}$TEST_EXPECTED_NODES${NC} (from PXC StatefulSet: $PXC_STS_NAME)"
fi

verbose_echo -e "${BLUE}Test Configuration:${NC}"
verbose_echo "  Namespace: $TEST_NAMESPACE"
verbose_echo "  Cluster Name: $TEST_CLUSTER_NAME"
verbose_echo "  Expected Nodes: $TEST_EXPECTED_NODES"
verbose_echo "  Backup Type: $TEST_BACKUP_TYPE"
if [ -n "$TEST_BACKUP_BUCKET" ]; then
    verbose_echo "  Backup Bucket: $TEST_BACKUP_BUCKET"
fi
verbose_echo ""

# Check if namespace exists
if ! kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
    verbose_echo -e "${YELLOW}⚠ Warning: Namespace '$TEST_NAMESPACE' does not exist${NC}"
    verbose_echo "Some tests may fail. Create the namespace and deploy Percona cluster first."
    verbose_echo ""
fi

# Parse command-line arguments
SHOW_WARNINGS=false
NO_RESILIENCY=false
NO_UNIT=false
NO_INTEGRATION=false
NO_DR=false
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
        --no-dr-tests)
            NO_DR=true
            EXPLICIT_FLAGS=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        *)
            # Unknown option - pass through to pytest if needed
            ;;
    esac
done

# Initialize pytest options
# Default: minimal output (just test names and PASS/FAIL)
# Verbose: detailed output with traces
if [ "$VERBOSE" = "true" ]; then
    PYTEST_OPTS=(
        "-v"
        "-s"  # Disable output capturing so console.print works immediately
        "--tb=short"
        "--color=yes"
    )
else
    # Minimal output: show test names with PASS/FAIL status
    PYTEST_OPTS=(
        "-v"  # Verbose: show test names (but we'll suppress other verbose output)
        "--tb=line"  # Minimal traceback (one line) for failures only
        "--color=yes"
        "-rN"  # No extra summary details for passed tests
    )
fi

# Do not enable chaos globally. Chaos is only enabled for resiliency/DR stages.

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
if [ "$NO_DR" == "true" ]; then
    if [ -n "$MARKER_EXPR" ]; then
        MARKER_EXPR="${MARKER_EXPR} and not dr"
    else
        MARKER_EXPR="not dr"
    fi
fi

# Add marker expression to pytest options if any exclusions specified
if [ -n "$MARKER_EXPR" ]; then
    PYTEST_OPTS+=("-m" "$MARKER_EXPR")
fi

# Run tests (only show category info if verbose)
verbose_echo -e "${BLUE}Running tests...${NC}"

# Display test categories being run (only if verbose)
if [ "$VERBOSE" = "true" ]; then
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
        if [ "$NO_DR" == "false" ]; then
            echo -e "  ${GREEN}✓${NC} DR scenario tests"
        else
            echo -e "  ${YELLOW}⊘${NC} DR scenario tests (excluded)"
        fi
    else
        echo -e "${BLUE}Running all test categories (unit, integration, resiliency with chaos)${NC}"
    fi
    echo ""
fi

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

# Helper to run one category with its own marker
run_category() {
    local category_name="$1"   # pretty name
    local marker_expr="$2"     # pytest -m expression
    local trigger_chaos="$3"   # true/false
    local test_path="$4"       # directory to run

    local OPTS=("${PYTEST_OPTS[@]}")
    # Replace any previous -m with category-specific marker
    # Build new opts without existing -m or --trigger-chaos
    local CLEAN_OPTS=()
    local SKIP_NEXT=false
    for opt in "${OPTS[@]}"; do
        if [ "$SKIP_NEXT" = true ]; then SKIP_NEXT=false; continue; fi
        if [ "$opt" = "-m" ]; then SKIP_NEXT=true; continue; fi
        if [ "$opt" = "--trigger-chaos" ]; then continue; fi
        CLEAN_OPTS+=("$opt")
    done
    OPTS=("${CLEAN_OPTS[@]}")
    if [ -n "$marker_expr" ]; then
        OPTS+=("-m" "$marker_expr")
    fi
    if [ "$trigger_chaos" = "true" ]; then
        OPTS+=("--trigger-chaos")
    fi

    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}=== ${category_name} ===${NC}"
        pytest "${OPTS[@]}" "$test_path"
        return $?
    else
        TEMP_OUTPUT=$(mktemp)
        pytest "${OPTS[@]}" "$test_path" > "$TEMP_OUTPUT" 2>&1
        local rc=$?
        awk '
        /^tests\/.*::/ {
            test_name = $1
            if (match($0, /PASSED|FAILED|ERROR/)) {
                status_line = $0
                if (match(status_line, /PASSED/)) status = "PASSED"
                else if (match(status_line, /FAILED/)) status = "FAILED"
                else if (match(status_line, /ERROR/)) status = "ERROR"
                print test_name " " status
            } else {
                pending_test = test_name
            }
        }
        /PASSED|FAILED|ERROR/ {
            if (pending_test != "" && !/^tests\//) {
                if (match($0, /PASSED/)) status = "PASSED"
                else if (match($0, /FAILED/)) status = "FAILED"
                else if (match($0, /ERROR/)) status = "ERROR"
                print pending_test " " status
                pending_test = ""
            }
        }
        ' "$TEMP_OUTPUT"
        rm -f "$TEMP_OUTPUT"
        return $rc
    fi
}

# Run categories in order: unit -> integration -> resiliency (incl. DR)
set +e
TEST_RESULT=0

if [ "$NO_UNIT" == "false" ]; then
    run_category "Unit tests" "unit" false "tests/unit"
    [ $? -ne 0 ] && TEST_RESULT=1
fi

if [ "$NO_INTEGRATION" == "false" ]; then
    run_category "Integration tests" "integration" false "tests/integration"
    [ $? -ne 0 ] && TEST_RESULT=1
fi

if [ "$NO_RESILIENCY" == "false" ]; then
    # Run resiliency (non-DR) first, then DR scenarios
    run_category "Resiliency tests" "resiliency and not dr" true "tests/resiliency"
    [ $? -ne 0 ] && TEST_RESULT=1
    if [ "$NO_DR" == "false" ]; then
        run_category "DR scenario tests" "dr" true "tests/resiliency"
        [ $? -ne 0 ] && TEST_RESULT=1
    fi
fi

# Skip warning counting if verbose (warnings already visible) or if explicitly showing warnings
if [ "$SHOW_WARNINGS" == "true" ] || [ "$VERBOSE" == "true" ]; then
    WARNING_COUNT=0
else
    # Count warnings by running again with warnings enabled (quietly, just to get count)
    # Only count warnings if we haven't excluded all categories (which would re-run everything)
    # Build the same test paths/markers that were actually run
    WARNING_OPTS=()
    SKIP_NEXT=false
    for opt in "${PYTEST_OPTS[@]}"; do
        if [ "$SKIP_NEXT" == "true" ]; then
            SKIP_NEXT=false
            WARNING_OPTS+=("default")
        elif [ "$opt" == "-W" ]; then
            SKIP_NEXT=true
            WARNING_OPTS+=("-W")
        elif [ "$opt" == "-s" ]; then
            # Skip -s (output capturing disabled) - causes issues when piping
            continue
        else
            WARNING_OPTS+=("$opt")
        fi
    done
    
    # Build test paths based on what was actually run
    WARNING_PATHS=()
    if [ "$NO_UNIT" == "false" ]; then
        WARNING_PATHS+=("tests/unit")
    fi
    if [ "$NO_INTEGRATION" == "false" ]; then
        WARNING_PATHS+=("tests/integration")
    fi
    if [ "$NO_RESILIENCY" == "false" ]; then
        if [ "$NO_DR" == "false" ]; then
            # Both resiliency and DR were run - include entire directory
            WARNING_PATHS+=("tests/resiliency")
        else
            # Only non-DR resiliency was run
            WARNING_PATHS+=("tests/resiliency")
        fi
    elif [ "$NO_DR" == "false" ]; then
        # Only DR tests were run
        WARNING_PATHS+=("tests/resiliency")
    fi
    
    # Only count warnings if we have paths to check
    # Using the same paths that were actually run prevents re-running all tests
    if [ ${#WARNING_PATHS[@]} -gt 0 ]; then
        # Run quietly to get warning count from summary (suppress all visible output)
        # Only run on the same paths that were executed, which prevents hanging
        WARNING_SUMMARY=$(pytest "${WARNING_OPTS[@]}" -q --tb=no "${WARNING_PATHS[@]}" 2>&1 | grep -oE "[0-9]+ warnings?" | grep -oE "[0-9]+" | head -1 || echo "0") 2>/dev/null
        if [ -n "$WARNING_SUMMARY" ] && [ "$WARNING_SUMMARY" -gt 0 ] 2>/dev/null; then
            WARNING_COUNT=$WARNING_SUMMARY
        else
            WARNING_COUNT=0
        fi
    else
        # No tests were run, so no warnings to count
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


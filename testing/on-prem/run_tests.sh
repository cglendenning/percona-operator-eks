#!/bin/bash
set -euo pipefail

# Test runner script for Percona XtraDB Cluster tests
# Can be run manually on Mac or in GitLab CI

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR"

# Validate we're in the correct directory structure
if [ ! -f "conftest.py" ] || [ ! -f "pytest.ini" ] || [ ! -f "requirements.txt" ]; then
    echo "ERROR: run_tests.sh must be run from the test suite directory" >&2
    echo "Expected files not found: conftest.py, pytest.ini, or requirements.txt" >&2
    echo "Current directory: $(pwd)" >&2
    echo "Script location: $SCRIPT_DIR" >&2
    echo "" >&2
    echo "You should run this script from:" >&2
    echo "  cd /path/to/percona_operator/testing/on-prem" >&2
    echo "  ./run_tests.sh" >&2
    exit 1
fi

# On-prem always uses Fleet - validate fleet.yaml exists
FLEET_YAML_CHECK="${FLEET_YAML:-./fleet.yaml}"
if [ ! -f "$FLEET_YAML_CHECK" ]; then
    echo "ERROR: fleet.yaml not found" >&2
    echo "Expected file: $FLEET_YAML_CHECK" >&2
    echo "Current directory: $(pwd)" >&2
    echo "" >&2
    echo "On-prem tests require a fleet.yaml configuration file." >&2
    echo "Either:" >&2
    echo "  1. Run from the directory containing fleet.yaml, OR" >&2
    echo "  2. Set FLEET_YAML environment variable:" >&2
    echo "     export FLEET_YAML=/path/to/fleet.yaml" >&2
    echo "" >&2
    echo "Optionally set FLEET_TARGET to select a specific target:" >&2
    echo "  export FLEET_TARGET=k8s-dev" >&2
    exit 1
fi

# Set PROJECT_ROOT for any scripts that need it (though on-prem doesn't use it)
PROJECT_ROOT="$(cd ../.. && pwd 2>/dev/null || pwd)"
export PROJECT_ROOT

# Clean up any Python cache that might cause issues
find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true

# Set PYTHONPATH so conftest can be imported as a module
export PYTHONPATH="${SCRIPT_DIR}:${PYTHONPATH:-}"

# Setup logging to /tmp with timestamp
LOG_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/tmp/percona_tests_${LOG_TIMESTAMP}.log"

# Function to strip ANSI color codes for clean log file
strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Redirect output to both screen (with colors) and log file (without colors)
exec > >(tee >(strip_colors >> "$LOG_FILE"))
exec 2>&1

# Record test run start
echo "Percona Test Run - $(date)"
echo "Log file: $LOG_FILE"
echo ""

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Check if running under WSL
        if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

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
    echo -e "  ${GREEN}--on-prem${NC}"
    echo "      On-prem mode: relax EKS/AWS-specific assertions and prefer hostname-based anti-affinity"
    echo "      Auto-detects Fleet configurations (fleet.yaml) and extracts chart URL and values files"
    echo ""
    echo -e "  ${GREEN}[Pytest passthrough]${NC}"
    echo "      Any unrecognized flags are forwarded to pytest. Useful ones:"
    echo "        --proxysql         Run ProxySQL tests (skip HAProxy tests)"
    echo "        -k <expr>         Filter tests by keyword"
    echo "        <nodeid>          Run a specific test (e.g., unit/test_x.py::test_y)"
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
    echo "  # On-prem mode with defaults (hostname topology, standard storageclass)"
    echo "  $0 --on-prem --no-integration-tests --no-resiliency-tests"
    echo ""
    echo "  # Run only ProxySQL tests (skip HAProxy)"
    echo "  $0 --no-integration-tests --no-resiliency-tests -- --proxysql"
    echo ""
    echo "  # Run a single unit test"
    echo "  $0 --no-integration-tests --no-resiliency-tests unit/test_percona_values_yaml.py::test_percona_values_pxc_configuration"
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
    echo "  ON_PREM                 'true' to enable on-prem defaults (also via --on-prem)"
    echo "  STORAGE_CLASS_NAME      StorageClass name for on-prem (default: standard in on-prem)"
    echo "  TOPOLOGY_KEY            Anti-affinity topology key (default: hostname in on-prem, zone in EKS)"
    echo "  VALUES_FILE             Path to values file to test (default: percona/templates/percona-values.yaml)"
    echo "  VALUES_ROOT_KEY         Root key wrapper if present (e.g., pxc-db)"
    echo "  PXC_PATH                Dot-path to PXC section (e.g., pxc-db.pxc)"
    echo "  PROXYSQL_PATH           Dot-path to ProxySQL section"
    echo "  HAPROXY_PATH            Dot-path to HAProxy section"
    echo "  BACKUP_PATH             Dot-path to backup section (or backup-enabled normalization)"
    echo "  FLEET_YAML              Path to fleet.yaml (default: ./fleet.yaml if present in on-prem mode)"
    echo "  FLEET_TARGET            Fleet targetCustomization name to use (default: auto-detect or first)"
    echo ""
}

# Parse arguments for help and verbose flags (before any setup work)
VERBOSE=false
ON_PREM=true  # Default to on-prem mode in this directory
for arg in "$@"; do
    case $arg in
        -h|--help)
            show_usage
            exit 0
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --on-prem)
            ON_PREM=true
            ;;
    esac
done

# Export VERBOSE so pytest hooks can check it
export VERBOSE

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
    # Check Homebrew Cellar (macOS only)
    if [ "$OS_TYPE" = "macos" ]; then
        # Look for python3.X in bin directories under Cellar
        CELLAR_PYTHON=$(find /opt/homebrew/Cellar/python@${version} -path "*/bin/python${version}" -type f 2>/dev/null | sort -V | tail -1)
        if [ -n "$CELLAR_PYTHON" ] && [ -x "$CELLAR_PYTHON" ] && "$CELLAR_PYTHON" --version >/dev/null 2>&1; then
            LATEST_CMD="$CELLAR_PYTHON"
            LATEST_VERSION="$version"
            break
        fi
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

# Verify we're actually using the venv Python
VENV_PYTHON="$SCRIPT_DIR/venv/bin/python"
if [ ! -x "$VENV_PYTHON" ]; then
    echo -e "${RED}✗ Virtual environment Python not found at $VENV_PYTHON${NC}" >&2
    exit 1
fi

# Use venv Python explicitly for all operations
"$VENV_PYTHON" -m pip install --upgrade pip >/dev/null 2>&1
"$VENV_PYTHON" -m pip install -q -r requirements.txt

verbose_echo -e "${GREEN}✓ Dependencies installed${NC}"

# Validate conftest can be imported (fail fast with diagnostics)
# Use venv Python explicitly to avoid system Python
verbose_echo -e "${BLUE}Validating test configuration...${NC}"
CONFTEST_CHECK=$("$VENV_PYTHON" -c "
import sys
import os
sys.path.insert(0, os.getcwd())
try:
    import conftest
    print('OK')
except ImportError as e:
    print(f'ERROR: {e}')
    print(f'Python executable: {sys.executable}')
    print(f'sys.path: {sys.path}')
    print(f'PYTHONPATH: {os.environ.get(\"PYTHONPATH\", \"not set\")}')
    print(f'cwd: {os.getcwd()}')
    print(f'conftest.py exists: {os.path.exists(\"conftest.py\")}')
" 2>&1)

if [[ "$CONFTEST_CHECK" != "OK" ]]; then
    echo -e "${RED}✗ Failed to import conftest module${NC}" >&2
    echo -e "${RED}This will cause 'ModuleNotFoundError: No module named conftest'${NC}" >&2
    echo ""
    echo -e "${YELLOW}Diagnostic information:${NC}"
    echo "$CONFTEST_CHECK"
    echo ""
    echo -e "${YELLOW}Current directory: ${NC}$(pwd)"
    echo -e "${YELLOW}PYTHONPATH: ${NC}${PYTHONPATH:-not set}"
    echo -e "${YELLOW}conftest.py exists: ${NC}$([ -f conftest.py ] && echo yes || echo no)"
    echo -e "${YELLOW}Venv Python: ${NC}$VENV_PYTHON"
    echo -e "${YELLOW}Which python: ${NC}$(which python)"
    echo ""
    echo -e "${RED}Please report this error - the test setup is misconfigured${NC}"
    exit 1
fi

verbose_echo -e "${GREEN}✓ Test configuration validated (using $VENV_PYTHON)${NC}"
verbose_echo ""

# Set default environment variables if not set
export TEST_NAMESPACE=${TEST_NAMESPACE:-percona}
export TEST_CLUSTER_NAME=${TEST_CLUSTER_NAME:-pxc-cluster}
export TEST_BACKUP_TYPE=${TEST_BACKUP_TYPE:-minio}
export TEST_BACKUP_BUCKET=${TEST_BACKUP_BUCKET:-percona-backups}
export TEST_OPERATOR_NAMESPACE=${TEST_OPERATOR_NAMESPACE:-$TEST_NAMESPACE}
export MINIO_NAMESPACE=${MINIO_NAMESPACE:-minio}
export CHAOS_NAMESPACE=${CHAOS_NAMESPACE:-litmus}
export ON_PREM=${ON_PREM}
# On-prem sensible defaults
if [ "$ON_PREM" = "true" ]; then
    export STORAGE_CLASS_NAME=${STORAGE_CLASS_NAME:-standard}
    export TOPOLOGY_KEY=${TOPOLOGY_KEY:-kubernetes.io/hostname}
    
    # Fleet configuration detection (on-prem environments often use Fleet)
    FLEET_YAML=${FLEET_YAML:-./fleet.yaml}
    if [ -f "$FLEET_YAML" ] && command -v python3 >/dev/null 2>&1 && command -v helm >/dev/null 2>&1; then
        verbose_echo -e "${BLUE}Detected Fleet configuration: $FLEET_YAML${NC}"
        
        # Extract Fleet configuration and render manifest using Python
        FLEET_RENDER=$(python3 - <<'PYTHON_SCRIPT'
import sys
import yaml
import os
import subprocess
import tempfile
import re
from datetime import datetime

fleet_path = os.getenv('FLEET_YAML', './fleet.yaml')
fleet_target = os.getenv('FLEET_TARGET', '')

try:
    # Get absolute path to fleet.yaml and its directory
    fleet_path_abs = os.path.abspath(fleet_path)
    fleet_dir = os.path.dirname(fleet_path_abs)
    
    with open(fleet_path_abs, 'r') as f:
        fleet = yaml.safe_load(f)
    
    # Extract base helm config
    helm_config = fleet.get('helm', {})
    chart_url = helm_config.get('chart', '')
    release_name = helm_config.get('releaseName', 'pxc-cluster')
    base_namespace = helm_config.get('targetNamespace', 'percona')
    base_values_files = helm_config.get('valuesFiles', [])
    
    # Find target customization
    target_customizations = fleet.get('targetCustomizations', [])
    target_values_files = []
    target_namespace = base_namespace
    
    if fleet_target:
        for target in target_customizations:
            if target.get('name') == fleet_target:
                target_helm = target.get('helm', {})
                target_values_files = target_helm.get('valuesFiles', [])
                target_namespace = target.get('namespace') or target_helm.get('targetNamespace', base_namespace)
                break
    elif target_customizations:
        target = target_customizations[0]
        target_helm = target.get('helm', {})
        target_values_files = target_helm.get('valuesFiles', [])
        target_namespace = target.get('namespace') or target_helm.get('targetNamespace', base_namespace)
    
    # Combine values files (base + target-specific)
    all_values_files = base_values_files + target_values_files
    
    # Build helm template command
    helm_cmd = ['helm', 'template', release_name, chart_url, '--insecure-skip-tls-verify']
    if target_namespace:
        helm_cmd.extend(['--namespace', target_namespace])
    
    for vf in all_values_files:
        helm_cmd.extend(['-f', vf])
    
    # Change to fleet.yaml directory so relative paths work
    original_cwd = os.getcwd()
    os.chdir(fleet_dir)
    
    # Run helm template
    result = subprocess.run(helm_cmd, capture_output=True, text=True, check=True, cwd=fleet_dir)
    rendered_manifest = result.stdout
    
    # Change back to original directory
    os.chdir(original_cwd)
    
    # Redact secrets
    manifest_docs = list(yaml.safe_load_all(rendered_manifest))
    for doc in manifest_docs:
        if doc and doc.get('kind') == 'Secret' and 'data' in doc:
            for key in doc['data']:
                doc['data'][key] = '[REDACTED]'
        if doc and doc.get('kind') == 'Secret' and 'stringData' in doc:
            for key in doc['stringData']:
                doc['stringData'][key] = '[REDACTED]'
    
    # Save to temp file
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    temp_file = f'/tmp/fleet-rendered-{timestamp}.yaml'
    with open(temp_file, 'w') as f:
        yaml.dump_all(manifest_docs, f, default_flow_style=False)
    
    # Print results
    print(f"CHART_URL={chart_url}")
    print(f"RELEASE_NAME={release_name}")
    print(f"NAMESPACE={target_namespace}")
    print(f"RENDERED_MANIFEST={temp_file}")
    print(f"FLEET_DIR={fleet_dir}")
    if all_values_files:
        print(f"VALUES_FILES={','.join(all_values_files)}")
    
except subprocess.CalledProcessError as e:
    print(f"ERROR=helm template failed: {e.stderr}", file=sys.stderr)
    print(f"Working directory: {fleet_dir}", file=sys.stderr)
    print(f"Values files: {all_values_files if 'all_values_files' in locals() else 'not set'}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR={str(e)}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
)
        
        if [ $? -eq 0 ]; then
            # Parse output
            while IFS='=' read -r key value; do
                case $key in
                    CHART_URL)
                        FLEET_CHART_URL="$value"
                        verbose_echo "  Chart URL: $FLEET_CHART_URL"
                        ;;
                    RELEASE_NAME)
                        FLEET_RELEASE_NAME="$value"
                        verbose_echo "  Release Name: $FLEET_RELEASE_NAME"
                        ;;
                    NAMESPACE)
                        if [ -z "${TEST_NAMESPACE:-}" ] || [ "$TEST_NAMESPACE" = "percona" ]; then
                            export TEST_NAMESPACE="$value"
                            verbose_echo "  Namespace: $TEST_NAMESPACE (from Fleet)"
                        fi
                        ;;
                    RENDERED_MANIFEST)
                        export FLEET_RENDERED_MANIFEST="$value"
                        verbose_echo "  Rendered Manifest: $FLEET_RENDERED_MANIFEST"
                        ;;
                    FLEET_DIR)
                        FLEET_DIR="$value"
                        verbose_echo "  Fleet Directory: $FLEET_DIR"
                        ;;
                    VALUES_FILES)
                        IFS=',' read -ra VF_ARRAY <<< "$value"
                        if [ ${#VF_ARRAY[@]} -gt 0 ] && [ -z "${VALUES_FILE:-}" ]; then
                            export VALUES_FILE="${VF_ARRAY[0]}"
                            verbose_echo "  Primary Values File: $VALUES_FILE"
                        fi
                        ;;
                esac
            done <<< "$FLEET_RENDER"
            
            # Auto-detect schema from first values file if present
            if [ -n "${VALUES_FILE:-}" ] && [ -f "$VALUES_FILE" ]; then
                if grep -q '^pxc-db:' "$VALUES_FILE" 2>/dev/null; then
                    verbose_echo "  Detected pxc-db wrapper in values"
                    export VALUES_ROOT_KEY=${VALUES_ROOT_KEY:-pxc-db}
                    export PXC_PATH=${PXC_PATH:-pxc-db.pxc}
                    export PROXYSQL_PATH=${PROXYSQL_PATH:-pxc-db.proxysql}
                    export HAPROXY_PATH=${HAPROXY_PATH:-pxc-db.haproxy}
                    export BACKUP_PATH=${BACKUP_PATH:-pxc-db.backup}
                fi
            fi
        else
            verbose_echo -e "${YELLOW}⚠ Could not render Fleet manifest${NC}"
        fi
    fi
else
    export STORAGE_CLASS_NAME=${STORAGE_CLASS_NAME:-gp3}
    export TOPOLOGY_KEY=${TOPOLOGY_KEY:-topology.kubernetes.io/zone}
fi

# Auto-detect node count from cluster if not set
if [ -z "${TEST_EXPECTED_NODES:-}" ]; then
    # Try to get node count from PXC StatefulSet
    # First try to find by name pattern (contains -pxc but not proxysql)
    # Use || true to prevent script exit if grep finds nothing (due to set -e)
    PXC_STS_NAME=$(kubectl get statefulset -n "$TEST_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '\-pxc' | grep -v proxysql | head -1 || true)
    if [ -n "$PXC_STS_NAME" ]; then
        PXC_STS=$(kubectl get statefulset "$PXC_STS_NAME" -n "$TEST_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
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
verbose_echo "  Test Directory: $SCRIPT_DIR"
verbose_echo "  Configuration Source: Fleet (${FLEET_YAML_CHECK})"
verbose_echo "  Fleet Target: ${FLEET_TARGET:-auto-detect first target}"
verbose_echo "  Percona Namespace: $TEST_NAMESPACE"
verbose_echo "  Operator Namespace: $TEST_OPERATOR_NAMESPACE"
verbose_echo "  MinIO Namespace: $MINIO_NAMESPACE"
verbose_echo "  Chaos Namespace: $CHAOS_NAMESPACE"
verbose_echo "  Mode: $( [ \"$ON_PREM\" = \"true\" ] && echo on-prem || echo eks/aws )"
verbose_echo "  StorageClass Name: $STORAGE_CLASS_NAME"
verbose_echo "  Anti-affinity Topology Key: $TOPOLOGY_KEY"
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
PYTEST_PASSTHROUGH=()
PASSTHROUGH_MODE=false

for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        PASSTHROUGH_MODE=true
        continue
    fi
    
    if [ "$PASSTHROUGH_MODE" = "true" ]; then
        PYTEST_PASSTHROUGH+=("$arg")
        continue
    fi
    
    case $arg in
        --show-warnings)
            SHOW_WARNINGS=true
            EXPLICIT_FLAGS=true
            ;;
        --run-resiliency-tests)
            # Legacy flag - kept for backwards compatibility
            # Default behavior now runs all tests including resiliency
            EXPLICIT_FLAGS=true
            ;;
        --no-resiliency-tests)
            NO_RESILIENCY=true
            EXPLICIT_FLAGS=true
            ;;
        --no-unit-tests)
            NO_UNIT=true
            EXPLICIT_FLAGS=true
            ;;
        --no-integration-tests)
            NO_INTEGRATION=true
            EXPLICIT_FLAGS=true
            ;;
        --no-dr-tests)
            NO_DR=true
            EXPLICIT_FLAGS=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --on-prem)
            # Already handled in early scan, skip here
            ;;
        *)
            # Unknown option - assume it's for pytest
            PYTEST_PASSTHROUGH+=("$arg")
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
        "-v"  # Show individual test names
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
    PYTEST_OPTS+=("--html=report.html" "--self-contained-html")
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

    # Add passthrough arguments
    local FINAL_TEST_PATH="$test_path"
    
    # Check if passthrough contains a test path/nodeid
    for arg in "${PYTEST_PASSTHROUGH[@]+"${PYTEST_PASSTHROUGH[@]}"}"; do
        # If it looks like a test path (starts with tests/ or contains ::), use it as the path
        if [[ "$arg" =~ ^(unit|integration|resiliency)/ ]] || [[ "$arg" =~ :: ]]; then
            FINAL_TEST_PATH="$arg"
        else
            # Otherwise, add as pytest option
            OPTS+=("$arg")
        fi
    done

    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}=== ${category_name} ===${NC}"
    fi
    # Always show pytest output (it's already concise in non-verbose mode)
    # Use venv Python explicitly to ensure correct environment
    "$VENV_PYTHON" -m pytest "${OPTS[@]}" "$FINAL_TEST_PATH"
    return $?
}

# Check if a specific test path/nodeid was provided
SPECIFIC_TEST_PATH=""
for arg in "${PYTEST_PASSTHROUGH[@]+"${PYTEST_PASSTHROUGH[@]}"}"; do
    if [[ "$arg" =~ ^(unit|integration|resiliency)/ ]] || [[ "$arg" =~ :: ]]; then
        SPECIFIC_TEST_PATH="$arg"
        break
    fi
done

# Run categories in order: unit -> integration -> resiliency (incl. DR)
# OR run specific test if provided
set +e
TEST_RESULT=0

if [ -n "$SPECIFIC_TEST_PATH" ]; then
    # Run specific test directly without category filtering
    verbose_echo -e "${BLUE}Running specific test: ${SPECIFIC_TEST_PATH}${NC}"
    verbose_echo ""
    
    SPECIFIC_OPTS=("${PYTEST_OPTS[@]}")
    # Add passthrough args (excluding the test path which we'll use separately)
    for arg in "${PYTEST_PASSTHROUGH[@]+"${PYTEST_PASSTHROUGH[@]}"}"; do
        if [[ "$arg" != "$SPECIFIC_TEST_PATH" ]]; then
            SPECIFIC_OPTS+=("$arg")
        fi
    done
    
    # Always show pytest output (it's already concise in non-verbose mode)
    # Use venv Python explicitly to ensure correct environment
    "$VENV_PYTHON" -m pytest "${SPECIFIC_OPTS[@]}" "$SPECIFIC_TEST_PATH"
    TEST_RESULT=$?
else
    # Run by category as before
    if [ "$NO_UNIT" == "false" ]; then
        run_category "Unit tests" "unit" false "unit"
        [ $? -ne 0 ] && TEST_RESULT=1
    fi

    if [ "$NO_INTEGRATION" == "false" ]; then
        run_category "Integration tests" "integration" false "integration"
        [ $? -ne 0 ] && TEST_RESULT=1
    fi

    if [ "$NO_RESILIENCY" == "false" ]; then
        # Run resiliency (non-DR) first, then DR scenarios
        run_category "Resiliency tests" "resiliency and not dr" true "resiliency"
        [ $? -ne 0 ] && TEST_RESULT=1
        if [ "$NO_DR" == "false" ]; then
            run_category "DR scenario tests" "dr" true "resiliency"
            [ $? -ne 0 ] && TEST_RESULT=1
        fi
    fi
fi

echo ""
echo -e "${BLUE}Completing test run...${NC}"

# Clean up Fleet rendered manifest if it exists
if [ -n "${FLEET_RENDERED_MANIFEST:-}" ] && [ -f "$FLEET_RENDERED_MANIFEST" ]; then
    verbose_echo "Cleaning up rendered Fleet manifest: $FLEET_RENDERED_MANIFEST"
    rm -f "$FLEET_RENDERED_MANIFEST"
fi

# Skip warning counting - it can hang with fixtures and isn't critical
# Warnings are visible if user runs with --show-warnings
WARNING_COUNT=0
set -e

echo ""
echo -e "${BLUE}========================================${NC}"
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed! ✓${NC}"
else
    echo -e "${RED}Some tests failed ✗${NC}"
fi
echo -e "${BLUE}========================================${NC}"

# Show warning message if warnings were suppressed
if [ "$SHOW_WARNINGS" == "false" ]; then
    echo ""
    echo -e "${BLUE}Python warnings were suppressed. To see them, run with: --show-warnings${NC}"
fi

if [ "${GENERATE_HTML_REPORT:-}" == "true" ]; then
    echo ""
    echo -e "${GREEN}HTML report generated: report.html${NC}"
fi

# Show log file location
echo ""
echo -e "${BLUE}Full test log saved to:${NC} ${LOG_FILE}"
echo "View log: cat ${LOG_FILE}"

exit $TEST_RESULT


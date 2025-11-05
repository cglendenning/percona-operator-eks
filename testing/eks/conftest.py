"""
Pytest configuration and shared fixtures for EKS test suite.
"""
import os
import pytest
import yaml
import sys

# Add the parent directory to the path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Test markers
def pytest_configure(config):
    config.addinivalue_line("markers", "unit: unit tests")
    config.addinivalue_line("markers", "integration: integration tests")
    config.addinivalue_line("markers", "resiliency: resiliency tests")
    config.addinivalue_line("markers", "dr_scenario: disaster recovery scenario tests")


# Environment variables for test configuration
TEST_NAMESPACE = os.getenv('TEST_NAMESPACE', 'percona')
TEST_CLUSTER_NAME = os.getenv('TEST_CLUSTER_NAME', 'pxc-cluster')
TEST_EXPECTED_NODES = int(os.getenv('TEST_EXPECTED_NODES', '3'))
BACKUP_TYPE = os.getenv('BACKUP_TYPE', 'minio')
BACKUP_BUCKET = os.getenv('BACKUP_BUCKET', 'percona-backups')
CHARTMUSEUM_NAMESPACE = os.getenv('CHARTMUSEUM_NAMESPACE', 'chartmuseum')
TEST_OPERATOR_NAMESPACE = os.getenv('TEST_OPERATOR_NAMESPACE', TEST_NAMESPACE)
MINIO_NAMESPACE = os.getenv('MINIO_NAMESPACE', 'minio')
CHAOS_NAMESPACE = os.getenv('CHAOS_NAMESPACE', 'litmus')

# EKS-specific defaults (no ON_PREM logic)
STORAGE_CLASS_NAME = os.getenv('STORAGE_CLASS_NAME', 'gp3')
TOPOLOGY_KEY = os.getenv('TOPOLOGY_KEY', 'topology.kubernetes.io/zone')

# Values file path
VALUES_FILE = os.path.join(os.getcwd(), 'percona', 'templates', 'percona-values.yaml')


def _load_values_yaml() -> dict:
    """Load and parse the Percona values YAML file."""
    with open(VALUES_FILE, 'r', encoding='utf-8') as f:
        content = f.read()
    # Replace common placeholders
    content = content.replace('{{NODES}}', str(TEST_EXPECTED_NODES))
    try:
        return yaml.safe_load(content) or {}
    except Exception:
        return {}


@pytest.fixture(scope='session')
def values_norm():
    """
    Return normalized Percona values for tests.
    For EKS, we load directly from percona-values.yaml.
    """
    return _load_values_yaml()


@pytest.fixture(scope='session')
def is_proxysql(request):
    """
    Check if --proxysql flag was provided.
    Returns True if testing ProxySQL configuration, False for HAProxy (default).
    """
    return request.config.getoption("--proxysql", default=False)


def pytest_addoption(parser):
    """Add custom command-line options."""
    parser.addoption(
        "--proxysql",
        action="store_true",
        default=False,
        help="Run ProxySQL-specific tests instead of HAProxy tests"
    )


def get_values_for_test():
    """
    Helper to get values dictionary and source path for tests.
    For EKS, always returns the raw percona-values.yaml.
    """
    path = VALUES_FILE
    values = _load_values_yaml()
        return (values, path)


def log_check(criterion: str, expected: str, actual: str, source: str = ""):
    """
    Log a criterion/result pair for test assertions in verbose mode.

    Example:
      Criterion: pxc size should be in [3,5]
      Result:    pxc size = 3 (source: percona/templates/percona-values.yaml)
    """
    prefix = "[dim]"
    if source:
        print(f"{prefix}Criterion: {criterion}")
        print(f"{prefix}Expected:  {expected}")
        print(f"{prefix}Actual:    {actual} (source: {source})")
    else:
        print(f"{prefix}Criterion: {criterion}")
        print(f"{prefix}Expected:  {expected}")
        print(f"{prefix}Actual:    {actual}")


def pytest_runtest_setup(item):
    """
    Hook to run before each test (setup phase).
    Display test description in verbose mode.
    """
    if item.config.option.verbose > 0:
        # Get the test's docstring if available
        if item.obj.__doc__:
            desc = item.obj.__doc__.strip().split('\n')[0]
            print(f"\n=== Test: {item.nodeid}")
            print(f"Context: namespace={TEST_NAMESPACE}, operator_ns={TEST_OPERATOR_NAMESPACE}, "
                  f"minio_ns={MINIO_NAMESPACE}, chaos_ns={CHAOS_NAMESPACE}, cluster={TEST_CLUSTER_NAME}, "
                  f"expected_nodes={TEST_EXPECTED_NODES}, backup_type={BACKUP_TYPE}, "
                  f"backup_bucket={BACKUP_BUCKET}")
            print(f"Description: {desc}")


def pytest_runtest_logreport(item, when, report):
    """
    Hook to run after each test phase (call phase).
    Display detailed pass/fail/skip reasons with environment context in verbose mode.
    """
    if when == "call" and item.config.option.verbose > 0:
    if report.passed:
            print(f"[green]✓ PASSED[/green]")
        elif report.failed:
            print(f"[red]✗ FAILED[/red]")
            if report.longrepr:
                print(f"Reason: {report.longreprtext}")
    elif report.skipped:
            print(f"[yellow]⊘ SKIPPED[/yellow]")
            if hasattr(report, 'wasxfail'):
                print(f"Reason: {report.wasxfail}")


# Fixtures for ChartMuseum port-forward (used by some integration tests)
@pytest.fixture(scope="session")
def chartmuseum_port_forward():
    """
    Port-forward to ChartMuseum for the duration of the test session.
    """
    import subprocess
    import time
    
    # Start port-forward
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", CHARTMUSEUM_NAMESPACE, "svc/chartmuseum", "8080:8080"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
    # Wait a moment for port-forward to establish
    time.sleep(2)
    
    yield "http://localhost:8080"
    
    # Cleanup
    proc.terminate()
    proc.wait()


# Fixture for resiliency tests to trigger chaos
@pytest.fixture(scope="function")
def trigger_chaos_for_resiliency_tests():
    """
    Fixture that resiliency tests can use to trigger chaos experiments.
    This is a placeholder - actual chaos triggering is done by individual tests.
    """
    yield

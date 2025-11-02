"""
Pytest configuration and shared fixtures for Percona XtraDB Cluster tests
"""
import os
import subprocess
import json
import warnings
import pytest
from kubernetes import client, config
from rich.console import Console

# Suppress urllib3 warnings about OpenSSL
warnings.filterwarnings('ignore', category=UserWarning, module='urllib3')
try:
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.NotOpenSSLWarning)
except (ImportError, AttributeError):
    pass

console = Console()

# Add custom pytest option for MTTR timeout
def pytest_addoption(parser):
    """Add custom command-line options"""
    parser.addoption(
        '--mttr-timeout',
        action='store',
        default=os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', '120'),
        type=int,
        help='MTTR timeout in seconds for resiliency tests (default: 120)'
    )

# Pytest markers for test categorization
pytest_plugins = []

# Test configuration from environment variables
TEST_NAMESPACE = os.getenv('TEST_NAMESPACE', 'percona')
TEST_CLUSTER_NAME = os.getenv('TEST_CLUSTER_NAME', 'pxc-cluster')
TEST_EXPECTED_NODES = int(os.getenv('TEST_EXPECTED_NODES', '6'))
TEST_BACKUP_TYPE = os.getenv('TEST_BACKUP_TYPE', 'minio')  # 's3' or 'minio' (default: minio for on-prem replication)
TEST_BACKUP_BUCKET = os.getenv('TEST_BACKUP_BUCKET', '')
TEST_OPERATOR_NAMESPACE = os.getenv('TEST_OPERATOR_NAMESPACE', TEST_NAMESPACE)


@pytest.fixture(scope="session")
def k8s_client():
    """Initialize Kubernetes API client"""
    try:
        config.load_incluster_config()
        console.print("[green]✓[/green] Using in-cluster Kubernetes config")
    except config.ConfigException:
        try:
            config.load_kube_config()
            console.print("[green]✓[/green] Using local Kubernetes config")
        except Exception as e:
            pytest.fail(f"Could not load Kubernetes config: {e}")
    
    return client.ApiClient()


@pytest.fixture(scope="session")
def core_v1(k8s_client):
    """Core V1 API client"""
    return client.CoreV1Api(k8s_client)


@pytest.fixture(scope="session")
def apps_v1(k8s_client):
    """Apps V1 API client"""
    return client.AppsV1Api(k8s_client)


@pytest.fixture(scope="session")
def custom_objects_v1(k8s_client):
    """Custom Objects V1 API client"""
    return client.CustomObjectsApi(k8s_client)


@pytest.fixture(scope="session")
def policy_v1(k8s_client):
    """Policy V1 API client"""
    return client.PolicyV1Api(k8s_client)


@pytest.fixture(scope="session")
def storage_v1(k8s_client):
    """Storage V1 API client"""
    return client.StorageV1Api(k8s_client)


def kubectl_cmd(cmd_list):
    """Execute kubectl command and return JSON result"""
    try:
        result = subprocess.run(
            ['kubectl'] + cmd_list + ['-o', 'json'],
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        console.print(f"[red]✗ kubectl command failed:[/red] {' '.join(cmd_list)}")
        console.print(f"[red]Error:[/red] {e.stderr}")
        raise
    except json.JSONDecodeError as e:
        console.print(f"[red]✗ Failed to parse JSON:[/red] {e}")
        raise


def helm_template(chart_name, namespace, values_file=None, values_dict=None):
    """Render Helm chart template"""
    cmd = ['helm', 'template', chart_name, 'percona/pxc-db', '-n', namespace]
    
    if values_file:
        cmd.extend(['-f', values_file])
    
    if values_dict:
        import yaml
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
            yaml.dump(values_dict, f)
            cmd.extend(['-f', f.name])
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        console.print(f"[red]✗ Helm template failed:[/red] {e.stderr}")
        raise


def check_cluster_connectivity():
    """Verify we can connect to the Kubernetes cluster"""
    try:
        result = subprocess.run(
            ['kubectl', 'cluster-info'],
            capture_output=True,
            text=True,
            timeout=10
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        return False


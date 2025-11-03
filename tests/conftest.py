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

# ChartMuseum port-forward configuration
CHARTMUSEUM_NAMESPACE = 'chartmuseum'
CHARTMUSEUM_SERVICE = 'chartmuseum'
CHARTMUSEUM_LOCAL_PORT = 8765

# Add custom pytest option for MTTR timeout and chaos triggering
def pytest_addoption(parser):
    """Add custom command-line options"""
    parser.addoption(
        '--mttr-timeout',
        action='store',
        default=os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', '120'),
        type=int,
        help='MTTR timeout in seconds for resiliency tests (default: 120)'
    )
    parser.addoption(
        '--trigger-chaos',
        action='store_true',
        default=False,
        help='Trigger chaos experiments before running resiliency tests'
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
    cmd = ['helm', 'template', chart_name, 'internal/pxc-db', '-n', namespace]
    
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


@pytest.fixture(scope="module")
def chartmuseum_port_forward(request):
    """
    Set up port-forwarding to ChartMuseum for tests that need to access internal Helm charts.
    This fixture is module-scoped, so the port-forward is shared across tests in the same module.
    """
    import time
    import signal
    
    port_forward_process = None
    
    # Check if we're in verbose mode
    verbose = request.config.getoption('verbose', 0) > 0
    
    try:
        # Check if ChartMuseum is available
        check_result = subprocess.run(
            ['kubectl', 'get', 'svc', '-n', CHARTMUSEUM_NAMESPACE, CHARTMUSEUM_SERVICE],
            capture_output=True,
            timeout=10
        )
        
        if check_result.returncode != 0:
            pytest.skip("ChartMuseum is not available")
        
        # Start port-forward (silently unless verbose)
        if verbose:
            print(f"\n[ChartMuseum] Setting up port-forward on localhost:{CHARTMUSEUM_LOCAL_PORT}")
        
        port_forward_process = subprocess.Popen(
            [
                'kubectl', 'port-forward',
                '-n', CHARTMUSEUM_NAMESPACE,
                f'svc/{CHARTMUSEUM_SERVICE}',
                f'{CHARTMUSEUM_LOCAL_PORT}:8080'
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
        # Wait for port-forward to be ready
        time.sleep(3)
        
        # Check if port-forward is still running
        if port_forward_process.poll() is not None:
            stderr = port_forward_process.stderr.read().decode() if port_forward_process.stderr else ""
            pytest.skip(f"Port-forward to ChartMuseum failed to start: {stderr}")
        
        # Add internal Helm repo pointing to localhost
        try:
            subprocess.run(
                ['helm', 'repo', 'remove', 'internal'],
                capture_output=True,
                timeout=10
            )
        except:
            pass  # Repo might not exist
        
        add_result = subprocess.run(
            ['helm', 'repo', 'add', 'internal', f'http://localhost:{CHARTMUSEUM_LOCAL_PORT}'],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if add_result.returncode != 0:
            if port_forward_process:
                port_forward_process.terminate()
            pytest.skip(f"Failed to add internal Helm repo: {add_result.stderr}")
        
        # Update repos
        subprocess.run(
            ['helm', 'repo', 'update'],
            capture_output=True,
            timeout=30
        )
        
        if verbose:
            print("[ChartMuseum] Port-forward established")
        
        yield f'http://localhost:{CHARTMUSEUM_LOCAL_PORT}'
        
    finally:
        # Cleanup (silently)
        if port_forward_process:
            try:
                port_forward_process.terminate()
                port_forward_process.wait(timeout=5)
            except:
                try:
                    port_forward_process.kill()
                except:
                    pass  # Process already dead
            
            if verbose:
                print("\n[ChartMuseum] Port-forward closed")


@pytest.fixture(scope="session", autouse=True)
def trigger_chaos_for_resiliency_tests(request):
    """
    Automatically trigger chaos experiments before running resiliency tests.
    This fixture runs once per test session and triggers chaos if:
    - --trigger-chaos flag is set, OR
    - RUN_RESILIENCY_TESTS environment variable is set to 'true'
    
    Note: This only triggers chaos and waits for completion. The actual resiliency
    tests (which verify recovery) are run by pytest as normal test functions.
    """
    should_trigger = (
        request.config.getoption('--trigger-chaos', default=False) or
        os.getenv('RUN_RESILIENCY_TESTS', 'false').lower() == 'true'
    )
    
    # Only run if we're actually running resiliency tests
    if not should_trigger:
        yield
        return
    
    console.print("[bold cyan]Chaos fixture: Preparing to trigger chaos experiments...[/bold cyan]")
    console.print("[dim]Note: Tests will run and verify recovery even if chaos experiments complete before tests start[/dim]")
    
    try:
        from tests.resiliency.chaos_integration import (
            trigger_chaos_experiment,
            wait_for_chaos_completion
        )
        
        console.print("[bold cyan]Triggering chaos experiments for resiliency tests...[/bold cyan]")
        console.print("[dim]This may take a few minutes as chaos experiments run...[/dim]")
        
        chaos_namespace = os.getenv('CHAOS_NAMESPACE', 'litmus')
        mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', '120'))
        
        # Trigger chaos for PXC pods
        console.print("[cyan]Triggering pod-delete chaos for PXC StatefulSet...[/cyan]")
        console.print("[dim]Creating ChaosEngine and waiting for chaos to occur...[/dim]")
        pxc_engine = trigger_chaos_experiment(
            experiment_type='pod-delete',
            app_namespace=TEST_NAMESPACE,
            app_label='app.kubernetes.io/component=pxc',
            app_kind='statefulset',
            chaos_namespace=chaos_namespace,
            total_chaos_duration=60,
            chaos_interval=10
        )
        
        if pxc_engine:
            console.print(f"[dim]Waiting for PXC chaos experiment '{pxc_engine}' to complete (this may take up to 10 minutes)...[/dim]")
            wait_for_chaos_completion(chaos_namespace, pxc_engine, timeout=600)
            console.print("[green]✓ PXC chaos experiment completed[/green]")
        else:
            console.print("[yellow]⚠ PXC chaos engine was not created, continuing anyway...[/yellow]")
        
        # Wait a bit before triggering next chaos
        import time
        console.print("[dim]Waiting 5 seconds before triggering next chaos experiment...[/dim]")
        time.sleep(5)
        
        # Trigger chaos for ProxySQL pods
        console.print("[cyan]Triggering pod-delete chaos for ProxySQL StatefulSet...[/cyan]")
        console.print("[dim]Creating ChaosEngine and waiting for chaos to occur...[/dim]")
        proxysql_engine = trigger_chaos_experiment(
            experiment_type='pod-delete',
            app_namespace=TEST_NAMESPACE,
            app_label='app.kubernetes.io/component=proxysql',
            app_kind='statefulset',
            chaos_namespace=chaos_namespace,
            total_chaos_duration=60,
            chaos_interval=10
        )
        
        if proxysql_engine:
            console.print(f"[dim]Waiting for ProxySQL chaos experiment '{proxysql_engine}' to complete (this may take up to 10 minutes)...[/dim]")
            wait_for_chaos_completion(chaos_namespace, proxysql_engine, timeout=600)
            console.print("[green]✓ ProxySQL chaos experiment completed[/green]")
        else:
            console.print("[yellow]⚠ ProxySQL chaos engine was not created, continuing anyway...[/yellow]")
        
        console.print("[bold green]✓ All chaos experiments completed, proceeding with resiliency tests[/bold green]")
        console.print("[dim]Resiliency tests will now verify recovery from the chaos events...[/dim]")
        
        # Store engine names for cleanup later
        request.session.chaos_engines = [e for e in [pxc_engine, proxysql_engine] if e]
        
    except Exception as e:
        import traceback
        console.print(f"[red]✗ Failed to trigger chaos experiments: {e}[/red]")
        console.print(f"[dim]Traceback: {traceback.format_exc()}[/dim]")
        console.print("[yellow]⚠ Continuing without chaos experiments - tests will still run[/yellow]")
        request.session.chaos_engines = []
    
    yield
    
    # Cleanup chaos engines after tests complete
    try:
        if hasattr(request.session, 'chaos_engines') and request.session.chaos_engines:
            from kubernetes import client, config
            config.load_kube_config()
            custom_objects_v1 = client.CustomObjectsApi()
            chaos_namespace = os.getenv('CHAOS_NAMESPACE', 'litmus')
            
            for engine_name in request.session.chaos_engines:
                try:
                    custom_objects_v1.delete_namespaced_custom_object(
                        group='litmuschaos.io',
                        version='v1alpha1',
                        namespace=chaos_namespace,
                        plural='chaosengines',
                        name=engine_name
                    )
                    console.print(f"[dim]Cleaned up ChaosEngine: {engine_name}[/dim]")
                except Exception:
                    pass  # Ignore cleanup errors
    except Exception:
        pass  # Ignore cleanup errors


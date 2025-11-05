"""
Test that Kubernetes version is compatible with Percona Operator (>= 1.24)
"""
import pytest
import json
import subprocess
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_kubernetes_version_compatibility():
    """Test that Kubernetes version is compatible with Percona Operator (>= 1.24)"""
    result = subprocess.run(
        ['kubectl', 'version', '--output=json'],
        capture_output=True,
        text=True,
        check=True
    )
    version_info = json.loads(result.stdout)

    # Extract server version
    server_version = version_info['serverVersion']['gitVersion']
    # Remove 'v' prefix and get major.minor
    version_parts = server_version.lstrip('v').split('.')
    major = int(version_parts[0])
    minor = int(version_parts[1])

    console.print(f"[cyan]Kubernetes Version:[/cyan] {major}.{minor}")

    assert major > 1 or (major == 1 and minor >= 24), \
        f"Kubernetes version {major}.{minor} is too old. Percona Operator requires >= 1.24"

"""
Test that Helm release exists for the cluster
"""
import pytest
import json
import subprocess
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_helm_release_exists():
    """Test that Helm release exists for the cluster"""
    result = subprocess.run(
        ['helm', 'list', '-n', TEST_NAMESPACE, '--output', 'json'],
        capture_output=True,
        text=True,
        check=True
    )

    import json
    releases = json.loads(result.stdout)

    cluster_release = next(
        (r for r in releases if r['name'] == TEST_CLUSTER_NAME),
        None
    )

    assert cluster_release is not None, \
        f"Helm release '{TEST_CLUSTER_NAME}' not found in namespace '{TEST_NAMESPACE}'"

    console.print(f"[cyan]Helm Release Status:[/cyan] {cluster_release.get('status', 'unknown')}")
    assert cluster_release.get('status') == 'deployed', \
        f"Helm release is not deployed (status: {cluster_release.get('status')})"

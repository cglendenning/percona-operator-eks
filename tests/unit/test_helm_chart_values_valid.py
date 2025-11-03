"""
Test that Helm chart can be rendered with default values
"""
import pytest
import subprocess
import yaml
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.unit
def test_helm_chart_values_valid():
    """Test that Helm chart can be rendered with def ault values"""
    result = subprocess.run(
        ['helm', 'template', 'test-chart', 'internal/pxc-db', '--namespace', TEST_NAMESPACE],
        capture_output=True,
        text=True,
        timeout=30
    )

    assert result.returncode == 0, \
        f"Helm chart rendering failed: {result.stderr}"

    # Parse YAML output
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc:
            manifests.append(doc)

    assert len(manifests) > 0, "Helm chart produced no manifests"
    console.print(f"[cyan]Helm chart rendered:[/cyan] {len(manifests)} manifests")

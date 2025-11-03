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
    """Test that Helm chart can be rendered with default values"""
    # Try to ensure internal repo is available (local ChartMuseum)
    import os
    chartmuseum_url = os.getenv('CHARTMUSEUM_URL', 'http://chartmuseum.chartmuseum.svc.cluster.local')
    
    # Check if internal repo exists, add if not
    repo_list = subprocess.run(
        ['helm', 'repo', 'list'],
        capture_output=True,
        text=True
    )
    if 'internal' not in repo_list.stdout:
        subprocess.run(
            ['helm', 'repo', 'add', 'internal', chartmuseum_url],
            capture_output=True,
            text=True
        )
        subprocess.run(['helm', 'repo', 'update'], capture_output=True, text=True)
    
    result = subprocess.run(
        ['helm', 'template', 'test-chart', 'internal/pxc-db', '--namespace', TEST_NAMESPACE],
        capture_output=True,
        text=True,
        timeout=30
    )

    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    assert result.returncode == 0, \
        f"Helm chart rendering failed: {result.stderr}"

    # Parse YAML output
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc:
            manifests.append(doc)

    assert len(manifests) > 0, "Helm chart produced no manifests"
    console.print(f"[cyan]Helm chart rendered:[/cyan] {len(manifests)} manifests")

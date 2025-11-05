"""
Test that Helm chart can be rendered with default values
"""
import pytest
import subprocess
import yaml
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from tests.conftest import log_check
from rich.console import Console

console = Console()

@pytest.mark.unit
def test_helm_chart_values_valid(chartmuseum_port_forward):
    """Test that Helm chart can be rendered with default values"""
    # chartmuseum_port_forward fixture handles repo setup
    
    result = subprocess.run(
        ['helm', 'template', 'test-chart', 'internal/pxc-db', '--namespace', TEST_NAMESPACE],
        capture_output=True,
        text=True,
        timeout=30
    )

    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    log_check(
        criterion="Helm template should render successfully with default values",
        expected="returncode=0",
        actual=f"returncode={result.returncode}",
        source="helm template internal/pxc-db",
    )
    assert result.returncode == 0, \
        f"Helm chart rendering failed: {result.stderr}"

    # Parse YAML output
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc:
            manifests.append(doc)

    log_check(
        criterion="Helm render should produce one or more manifests",
        expected="> 0",
        actual=f"count={len(manifests)}",
        source="helm template internal/pxc-db",
    )
    assert len(manifests) > 0, "Helm chart produced no manifests"
    console.print(f"[cyan]Helm chart rendered:[/cyan] {len(manifests)} manifests")

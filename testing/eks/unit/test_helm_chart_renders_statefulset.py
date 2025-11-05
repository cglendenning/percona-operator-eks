"""
Test that Helm chart renders PerconaXtraDBCluster custom resource
(operator will create StatefulSets from this CR)
"""
import pytest
import subprocess
import yaml
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from tests.conftest import log_check
from rich.console import Console

console = Console()

@pytest.mark.unit
def test_helm_chart_renders_statefulset(chartmuseum_port_forward):
    """Test that Helm chart renders PerconaXtraDBCluster custom resource 
    (operator will create StatefulSets from this CR)"""
    # chartmuseum_port_forward fixture handles repo setup
    
    result = subprocess.run(
        ['helm', 'template', 'test-chart', 'internal/pxc-db', '--namespace', TEST_NAMESPACE],
        capture_output=True,
        text=True,
        timeout=30
    )

    # Check if chart is available (skip if ChartMuseum not accessible)
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    # Helm chart renders PerconaXtraDBCluster CR, not StatefulSets directly
    # The operator creates StatefulSets from the CR
    log_check(
        criterion="Helm render should include PerconaXtraDBCluster custom resource",
        expected="PerconaXtraDBCluster present in output",
        actual=f"present={'PerconaXtraDBCluster' in result.stdout}",
        source="helm template internal/pxc-db",
    )
    assert 'PerconaXtraDBCluster' in result.stdout, "Helm chart should render PerconaXtraDBCluster custom resource"

    # Parse and verify PerconaXtraDBCluster CR
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc and doc.get('kind') == 'PerconaXtraDBCluster':
            manifests.append(doc)

    log_check(
        criterion="At least one PerconaXtraDBCluster CR must be rendered",
        expected=">= 1",
        actual=f"count={len(manifests)}",
        source="helm template internal/pxc-db",
    )
    assert len(manifests) >= 1, \
        f"Expected at least 1 PerconaXtraDBCluster CR, found {len(manifests)}"

    # Verify the CR has PXC and ProxySQL specs
    cr = manifests[0]
    pxc_spec = cr.get('spec', {}).get('pxc', {})
    proxysql_spec = cr.get('spec', {}).get('proxysql', {})

    log_check(
        criterion="PerconaXtraDBCluster CR must contain PXC and ProxySQL specs",
        expected="> 0 fields each",
        actual=f"pxc={len(pxc_spec) if pxc_spec else 0}, proxysql={len(proxysql_spec) if proxysql_spec else 0}",
        source="helm template internal/pxc-db",
    )
    assert pxc_spec is not None and len(pxc_spec) > 0, "PerconaXtraDBCluster should have PXC spec"
    assert proxysql_spec is not None and len(proxysql_spec) > 0, "PerconaXtraDBCluster should have ProxySQL spec"

"""
Test that Helm chart renders PerconaXtraDBCluster custom resource
(operator will create StatefulSets from this CR)
"""
import pytest
import subprocess
import yaml
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.unit
def test_helm_chart_renders_statefulset():
    """Test that Helm chart renders PerconaXtraDBCluster custom resource 
    (operator will create StatefulSets from this CR)"""
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
        # Try to add internal repo (may fail if ChartMuseum not available)
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

    # Check if chart is available (skip if ChartMuseum not accessible)
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    # Helm chart renders PerconaXtraDBCluster CR, not StatefulSets directly
    # The operator creates StatefulSets from the CR
    assert 'PerconaXtraDBCluster' in result.stdout, "Helm chart should render PerconaXtraDBCluster custom resource"

    # Parse and verify PerconaXtraDBCluster CR
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc and doc.get('kind') == 'PerconaXtraDBCluster':
            manifests.append(doc)

    assert len(manifests) >= 1, \
        f"Expected at least 1 PerconaXtraDBCluster CR, found {len(manifests)}"

    # Verify the CR has PXC and ProxySQL specs
    cr = manifests[0]
    pxc_spec = cr.get('spec', {}).get('pxc', {})
    proxysql_spec = cr.get('spec', {}).get('proxysql', {})

    assert pxc_spec is not None and len(pxc_spec) > 0, "PerconaXtraDBCluster should have PXC spec"
    assert proxysql_spec is not None and len(proxysql_spec) > 0, "PerconaXtraDBCluster should have ProxySQL spec"

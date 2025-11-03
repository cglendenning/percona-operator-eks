"""
Test that Helm chart includes PVC configuration in PerconaXtraDBCluster spec
(operator will create PVCs from volumeSpec)
"""
import pytest
import subprocess
import yaml
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.unit
def test_helm_chart_renders_pvc():
    """Test that Helm chart includes PVC configuration in PerconaXtraDBCluster spec
    (operator will create PVCs from volumeSpec)"""
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

    # Check if chart is available (skip if ChartMuseum not accessible)
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")

    # Helm chart includes volumeSpec in the CR, operator creates PVCs
    manifests = list(yaml.safe_load_all(result.stdout))
    cr = next(
        (m for m in manifests if m.get('kind') == 'PerconaXtraDBCluster'),
        None
    )

    assert cr is not None, "PerconaXtraDBCluster not found in Helm chart"

    # Check for volumeSpec in PXC spec (indicates PVC configuration)
    pxc_spec = cr.get('spec', {}).get('pxc', {})
    volume_spec = pxc_spec.get('volumeSpec', {})
    pvc_spec = volume_spec.get('persistentVolumeClaim', {})

    assert pvc_spec is not None and len(pvc_spec) > 0, \
        "PerconaXtraDBCluster PXC spec should have persistentVolumeClaim volumeSpec"

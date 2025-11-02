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
    result = subprocess.run(
        ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
        capture_output=True,
        text=True,
        timeout=30
    )

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

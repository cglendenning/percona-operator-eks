"""
Test that Helm chart includes PVC configuration in PerconaXtraDBCluster spec
(operator will create PVCs from volumeSpec)
"""
import pytest
import subprocess
import yaml
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from conftest import log_check
from rich.console import Console

console = Console()

@pytest.mark.unit
def test_helm_chart_renders_pvc(chartmuseum_port_forward):
    """Test that Helm chart includes PVC configuration in PerconaXtraDBCluster spec
    (operator will create PVCs from volumeSpec)"""
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

    # Helm chart includes volumeSpec in the CR, operator creates PVCs
    manifests = list(yaml.safe_load_all(result.stdout))
    cr = next(
        (m for m in manifests if m.get('kind') == 'PerconaXtraDBCluster'),
        None
    )

    log_check(
        criterion="Helm render should include PerconaXtraDBCluster custom resource",
        expected="PerconaXtraDBCluster present",
        actual=f"present={cr is not None}",
        source="helm template internal/pxc-db",
    )
    assert cr is not None, "PerconaXtraDBCluster not found in Helm chart"

    # Check for volumeSpec in PXC spec (indicates PVC configuration)
    pxc_spec = cr.get('spec', {}).get('pxc', {})
    volume_spec = pxc_spec.get('volumeSpec', {})
    pvc_spec = volume_spec.get('persistentVolumeClaim', {})

    log_check(
        criterion="PXC spec must include volumeSpec.persistentVolumeClaim",
        expected="> 0 fields",
        actual=f"present={pvc_spec is not None}, size={len(pvc_spec) if pvc_spec else 0}",
        source="helm template internal/pxc-db",
    )
    assert pvc_spec is not None and len(pvc_spec) > 0, \
        "PerconaXtraDBCluster PXC spec should have persistentVolumeClaim volumeSpec"

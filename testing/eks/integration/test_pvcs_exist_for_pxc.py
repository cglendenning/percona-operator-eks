"""
Test that PVCs exist for PXC pods
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pvcs_exist_for_pxc(core_v1):
    """Test that PVCs exist for PXC pods"""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    assert len(pvcs.items) >= TEST_EXPECTED_NODES, \
        f"Expected at least {TEST_EXPECTED_NODES} PVCs for PXC, found {len(pvcs.items)}"

    console.print(f"[cyan]PXC PVCs Found:[/cyan] {len(pvcs.items)}")

    # Verify each PVC is bound
    for pvc in pvcs.items:
        assert pvc.status.phase == 'Bound', \
            f"PVC {pvc.metadata.name} is not Bound (status: {pvc.status.phase})"
        console.print(f"  ✓ {pvc.metadata.name}: {pvc.status.phase} ({pvc.spec.resources.requests.get('storage', 'unknown')})")

"""
Test that PXC PVCs have correct storage size (should be 20Gi from config)
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_pvc_storage_size(core_v1):
    """Test that PXC PVCs have correct storage size (should be 20Gi from config)"""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    expected_size = '20Gi'

    for pvc in pvcs.items:
        requested_size = pvc.spec.resources.requests.get('storage', '')
        console.print(f"[cyan]PVC {pvc.metadata.name}:[/cyan] {requested_size}")
        assert requested_size == expected_size, \
            f"PXC PVC {pvc.metadata.name} has incorrect size: {requested_size}, expected {expected_size}"

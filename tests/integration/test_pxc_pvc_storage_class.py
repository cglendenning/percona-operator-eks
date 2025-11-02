"""
Test that PXC PVCs use the correct storage class (gp3)
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_pvc_storage_class(core_v1):
    """Test that PXC PVCs use the correct storage class (gp3)"""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    for pvc in pvcs.items:
        storage_class = pvc.spec.storage_class_name
        console.print(f"[cyan]PVC {pvc.metadata.name} StorageClass:[/cyan] {storage_class}")
        assert storage_class == 'gp3', \
            f"PXC PVC {pvc.metadata.name} uses wrong storage class: {storage_class}, expected gp3"

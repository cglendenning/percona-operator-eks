"""
Test that PXC PVCs use the correct storage class (gp3)
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES, ON_PREM, STORAGE_CLASS_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_pvc_storage_class(core_v1):
    """Test that PXC PVCs use the expected storage class (gp3 on EKS, env-defined on on-prem)."""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    for pvc in pvcs.items:
        storage_class = pvc.spec.storage_class_name
        console.print(f"[cyan]PVC {pvc.metadata.name} StorageClass:[/cyan] {storage_class}")
        expected_sc = STORAGE_CLASS_NAME if ON_PREM else 'gp3'
        assert storage_class == expected_sc, \
            f"PXC PVC {pvc.metadata.name} uses wrong storage class: {storage_class}, expected {expected_sc}"

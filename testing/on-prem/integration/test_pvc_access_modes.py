"""
Test that PVCs have correct access modes (ReadWriteOnce)
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pvc_access_modes(core_v1):
    """Test that PVCs have correct access modes (ReadWriteOnce)"""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE
    )

    # Filter for Percona PVCs
    percona_pvcs = [
        pvc for pvc in pvcs.items
        if 'pxc' in pvc.metadata.name.lower() or 'proxysql' in pvc.metadata.name.lower()
    ]

    for pvc in percona_pvcs:
        access_modes = pvc.spec.access_modes
        assert 'ReadWriteOnce' in access_modes, \
            f"PVC {pvc.metadata.name} should have ReadWriteOnce access mode, got: {access_modes}"


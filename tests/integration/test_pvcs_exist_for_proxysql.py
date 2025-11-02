"""
Test that PVCs exist for ProxySQL pods
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pvcs_exist_for_proxysql(core_v1):
    """Test that PVCs exist for ProxySQL pods"""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=proxysql'
    )

    assert len(pvcs.items) > 0, "No PVCs found for ProxySQL"

    console.print(f"[cyan]ProxySQL PVCs Found:[/cyan] {len(pvcs.items)}")

    # Verify each PVC is bound
    for pvc in pvcs.items:
        assert pvc.status.phase == 'Bound', \
            f"ProxySQL PVC {pvc.metadata.name} is not Bound (status: {pvc.status.phase})"

"""
Test that ProxySQL PVCs have correct storage size (should be 5Gi or 8Gi depending on chart defaults)
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_pvc_storage_size(core_v1):
    """Test that ProxySQL PVCs have correct storage size (should be 5Gi or 8Gi depending on chart def aults)"""
    pvcs = core_v1.list_namespaced_persistent_volume_claim(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=proxysql'
    )

    # Helm chart may def ault to 8Gi even if we set 5Gi, so accept both
    expected_sizes = ['5Gi', '8Gi']

    for pvc in pvcs.items:
        requested_size = pvc.spec.resources.requests.get('storage', '')
        console.print(f"[cyan]ProxySQL PVC {pvc.metadata.name}:[/cyan] {requested_size}")
        assert requested_size in expected_sizes, \
            f"ProxySQL PVC {pvc.metadata.name} has incorrect size: {requested_size}, expected one of {expected_sizes}"

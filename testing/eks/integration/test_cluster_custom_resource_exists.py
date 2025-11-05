"""
Test that PXC custom resource exists
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_cluster_custom_resource_exists(custom_objects_v1):
    """Test that PXC custom resource exists"""
    try:
        cr = custom_objects_v1.get_namespaced_custom_object(
            group='pxc.percona.com',
            version='v1',
            namespace=TEST_NAMESPACE,
            plural='perconaxtradbclusters',
            name=f'{TEST_CLUSTER_NAME}-pxc-db'
        )

        console.print(f"[cyan]PXC CR Found:[/cyan] {cr['metadata']['name']}")
        console.print(f"[cyan]Status:[/cyan] {cr.get('status', {}).get('state', 'unknown')}")

        assert cr is not None, "PXC custom resource not found"
    except client.exceptions.ApiException as e:
        pytest.fail(f"PXC custom resource not found: {e}")

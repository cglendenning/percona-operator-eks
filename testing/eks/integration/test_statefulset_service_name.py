"""
Test that StatefulSets have correct service names
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_statefulset_service_name(apps_v1):
    """Test that StatefulSets have correct service names"""
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)

    for sts in sts_list.items:
        service_name = sts.spec.service_name
        assert service_name is not None and len(service_name) > 0, \
            f"StatefulSet {sts.metadata.name} has no service name"

        console.print(f"[cyan]{sts.metadata.name} ServiceName:[/cyan] {service_name}")

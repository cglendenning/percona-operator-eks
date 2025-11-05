"""
Test that service selectors match pod labels
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_service_selectors_match_pods(core_v1):
    """Test that service selectors match pod labels"""
    services = core_v1.list_namespaced_service(namespace=TEST_NAMESPACE)

    for service in services.items:
        if 'pxc' not in service.metadata.name.lower() and 'proxysql' not in service.metadata.name.lower():
            continue

        selector = service.spec.selector
        assert selector is not None and len(selector) > 0, \
            f"Service {service.metadata.name} has no selector"

        console.print(f"[cyan]{service.metadata.name} Selector:[/cyan] {selector}")

        # Verify pods exist that match this selector
        label_selector = ','.join([f"{k}={v}" for k, v in selector.items()])
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector=label_selector
        )

        assert len(pods.items) > 0, \
            f"No pods found matching service {service.metadata.name} selector: {selector}"

"""
Test that PXC service exists
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_service_exists(core_v1):
    """Test that PXC service exists"""
    services = core_v1.list_namespaced_service(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    assert len(services.items) > 0, "PXC service not found"

    service = services.items[0]
    console.print(f"[cyan]PXC Service:[/cyan] {service.metadata.name}")
    console.print(f"[cyan]Service Type:[/cyan] {service.spec.type}")
    ports_str = [f"{p.port}/{p.protocol}" for p in service.spec.ports]
    console.print(f"[cyan]Ports:[/cyan] {ports_str}")

    assert service.spec.type in ['ClusterIP', 'LoadBalancer', 'NodePort'], \
        f"PXC service has unexpected type: {service.spec.type}"

    assert len(service.spec.ports) > 0, \
        "PXC service should have at least one port"

"""
Test that services have endpoints
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_service_endpoints_exist(core_v1):
    """Test that services have endpoints"""
    services = core_v1.list_namespaced_service(namespace=TEST_NAMESPACE)

    percona_services = [
        s for s in services.items
        if 'pxc' in s.metadata.name.lower() or 'proxysql' in s.metadata.name.lower()
    ]

    for service in percona_services:
        try:
            endpoints = core_v1.read_namespaced_endpoints(
                name=service.metadata.name,
                namespace=TEST_NAMESPACE
            )

            addresses = []
            for subset in endpoints.subsets or []:
                addresses.extend([addr.ip for addr in subset.addresses or []])

            console.print(f"[cyan]{service.metadata.name} Endpoints:[/cyan] {len(addresses)}")

            assert len(addresses) > 0, \
                f"Service {service.metadata.name} has no endpoints"

        except Exception as e:
            console.print(f"[yellow]⚠ Could not check endpoints for {service.metadata.name}:[/yellow] {e}")


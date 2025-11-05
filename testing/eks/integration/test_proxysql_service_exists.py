"""
Test that ProxySQL service exists
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_service_exists(core_v1):
    """Test that ProxySQL service exists"""
    services = core_v1.list_namespaced_service(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=proxysql'
    )

    assert len(services.items) > 0, "ProxySQL service not found"

    service = services.items[0]
    console.print(f"[cyan]ProxySQL Service:[/cyan] {service.metadata.name}")
    console.print(f"[cyan]Service Type:[/cyan] {service.spec.type}")
    ports_str = [f"{p.port}/{p.protocol}" for p in service.spec.ports]
    console.print(f"[cyan]Ports:[/cyan] {ports_str}")

    # ProxySQL typically uses port 3306
    mysql_ports = [p for p in service.spec.ports if p.port == 3306]
    assert len(mysql_ports) > 0, \
        "ProxySQL service should expose port 3306"

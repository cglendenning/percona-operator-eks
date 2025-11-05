"""
Test that ProxySQL pods have resource requests configured
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_resource_requests(apps_v1):
    """Test that ProxySQL pods have resource requests configured"""
    # Get all StatefulSets and find ProxySQL by name pattern
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    proxysql_sts = [sts for sts in sts_list.items if 'proxysql' in sts.metadata.name]

    assert len(proxysql_sts) > 0, "ProxySQL StatefulSet not found"

    sts = proxysql_sts[0]
    containers = sts.spec.template.spec.containers

    proxysql_container = next(
        (c for c in containers if 'proxysql' in c.name.lower()),
        None
    )

    assert proxysql_container is not None, "ProxySQL container not found"

    resources = proxysql_container.resources
    assert resources is not None, "ProxySQL container should have resource limits/requests"

    requests = resources.requests or {}
    limits = resources.limits or {}

    console.print(f"[cyan]ProxySQL Resource Requests:[/cyan] {requests}")
    console.print(f"[cyan]ProxySQL Resource Limits:[/cyan] {limits}")

    assert 'cpu' in requests, "ProxySQL container should have CPU request"
    assert 'memory' in requests, "ProxySQL container should have memory request"

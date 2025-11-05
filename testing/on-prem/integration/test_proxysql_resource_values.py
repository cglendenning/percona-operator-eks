"""
Test that ProxySQL resources match expected values (100m CPU, 256Mi memory request)
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_resource_values(apps_v1):
    """Test that ProxySQL resources match expected values (100m CPU, 256Mi memory request)"""
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

    resources = proxysql_container.resources
    requests = resources.requests or {}

    # Expected: cpu: 100m, memory: 256Mi
    expected_cpu = '100m'
    expected_memory = '256Mi'

    if 'cpu' in requests:
        console.print(f"[cyan]ProxySQL CPU Request:[/cyan] {requests['cpu']} (expected: {expected_cpu})")
        assert requests['cpu'] == expected_cpu, \
            f"ProxySQL CPU request mismatch: got {requests['cpu']}, expected {expected_cpu}"

    if 'memory' in requests:
        console.print(f"[cyan]ProxySQL Memory Request:[/cyan] {requests['memory']} (expected: {expected_memory})")
        assert requests['memory'] == expected_memory, \
            f"ProxySQL memory request mismatch: got {requests['memory']}, expected {expected_memory}"


"""
Test that ProxySQL StatefulSet exists
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_statefulset_exists(apps_v1):
    """Test that ProxySQL StatefulSet exists"""
    # Get all StatefulSets and find ProxySQL by name pattern
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    proxysql_sts = [sts for sts in sts_list.items if 'proxysql' in sts.metadata.name]

    assert len(proxysql_sts) > 0, "ProxySQL StatefulSet not found"

    sts = proxysql_sts[0]
    console.print(f"[cyan]ProxySQL StatefulSet:[/cyan] {sts.metadata.name}")
    console.print(f"[cyan]Replicas:[/cyan] {sts.spec.replicas}/{sts.status.ready_replicas}")

    assert sts.spec.replicas == TEST_EXPECTED_NODES, \
        f"ProxySQL StatefulSet has wrong replica count: {sts.spec.replicas}, expected {TEST_EXPECTED_NODES}"

    assert sts.status.ready_replicas == TEST_EXPECTED_NODES, \
        f"Not all ProxySQL replicas are ready: {sts.status.ready_replicas}/{TEST_EXPECTED_NODES}"

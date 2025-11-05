"""
Test that cluster status is 'ready'
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_cluster_status_ready(custom_objects_v1):
    """Test that cluster status is 'ready'"""
    cr = custom_objects_v1.get_namespaced_custom_object(
        group='pxc.percona.com',
        version='v1',
        namespace=TEST_NAMESPACE,
        plural='perconaxtradbclusters',
        name=f'{TEST_CLUSTER_NAME}-pxc-db'
    )

    status = cr.get('status', {})
    state = status.get('state', 'unknown')

    console.print(f"[cyan]Cluster State:[/cyan] {state}")

    # Check PXC ready count
    pxc_status = status.get('pxc', {})
    if isinstance(pxc_status, dict):
        pxc_ready = pxc_status.get('ready', 0)
    else:
        pxc_ready = pxc_status

    # Check ProxySQL ready count
    proxysql_status = status.get('proxysql', {})
    if isinstance(proxysql_status, dict):
        proxysql_ready = proxysql_status.get('ready', 0)
    else:
        proxysql_ready = proxysql_status

    console.print(f"[cyan]PXC Ready:[/cyan] {pxc_ready}/{TEST_EXPECTED_NODES}")
    console.print(f"[cyan]ProxySQL Ready:[/cyan] {proxysql_ready}")

    assert state == 'ready', f"Cluster state is '{state}', expected 'ready'"
    assert pxc_ready >= TEST_EXPECTED_NODES, \
        f"Not all PXC nodes are ready: {pxc_ready}/{TEST_EXPECTED_NODES}"
    assert proxysql_ready > 0, "No ProxySQL pods are ready"


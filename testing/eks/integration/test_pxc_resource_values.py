"""
Test that PXC resources match expected values (500m CPU, 1Gi memory request)
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_resource_values(apps_v1):
    """Test that PXC resources match expected values (500m CPU, 1Gi memory request)"""
    # Get all StatefulSets and find PXC by name pattern
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    pxc_sts = [sts for sts in sts_list.items if '-pxc' in sts.metadata.name and 'proxysql' not in sts.metadata.name]

    assert len(pxc_sts) > 0, "PXC StatefulSet not found"
    sts = pxc_sts[0]
    containers = sts.spec.template.spec.containers

    pxc_container = next(
        (c for c in containers if 'pxc' in c.name.lower() or 'mysql' in c.name.lower()),
        None
    )

    resources = pxc_container.resources
    requests = resources.requests or {}

    # Expected: cpu: 500m, memory: 1Gi
    expected_cpu = '500m'
    expected_memory = '1Gi'

    if 'cpu' in requests:
        console.print(f"[cyan]PXC CPU Request:[/cyan] {requests['cpu']} (expected: {expected_cpu})")
        # Allow some flexibility in CPU values
        assert requests['cpu'] == expected_cpu, \
            f"PXC CPU request mismatch: got {requests['cpu']}, expected {expected_cpu}"

    if 'memory' in requests:
        console.print(f"[cyan]PXC Memory Request:[/cyan] {requests['memory']} (expected: {expected_memory})")
        assert requests['memory'] == expected_memory, \
            f"PXC memory request mismatch: got {requests['memory']}, expected {expected_memory}"

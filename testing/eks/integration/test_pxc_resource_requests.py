"""
Test that PXC pods have resource requests configured
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_resource_requests(apps_v1):
    """Test that PXC pods have resource requests configured"""
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

    assert pxc_container is not None, "PXC container not found in StatefulSet"

    resources = pxc_container.resources
    assert resources is not None, "PXC container should have resource limits/requests"

    requests = resources.requests or {}
    limits = resources.limits or {}

    console.print(f"[cyan]PXC Resource Requests:[/cyan] {requests}")
    console.print(f"[cyan]PXC Resource Limits:[/cyan] {limits}")

    # Verify CPU request exists
    assert 'cpu' in requests, "PXC container should have CPU request"
    assert 'memory' in requests, "PXC container should have memory request"

    # Verify limits exist
    assert 'cpu' in limits, "PXC container should have CPU limit"
    assert 'memory' in limits, "PXC container should have memory limit"

    # Verify limits are greater than or equal to requests
    if 'cpu' in requests and 'cpu' in limits:
        # Parse CPU values (e.g., "500m" -> 0.5, "1" -> 1.0)
        def parse_cpu(cpu_str):
            if cpu_str.endswith('m'):
                return float(cpu_str[:-1]) / 1000
            return float(cpu_str)

        request_cpu = parse_cpu(str(requests['cpu']))
        limit_cpu = parse_cpu(str(limits['cpu']))
        assert limit_cpu >= request_cpu, \
            f"PXC CPU limit ({limits['cpu']}) should be >= request ({requests['cpu']})"

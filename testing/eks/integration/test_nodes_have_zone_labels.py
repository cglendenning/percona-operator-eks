"""
Test that nodes have zone labels for anti-affinity to work
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_nodes_have_zone_labels(core_v1):
    """Test that nodes have zone labels for anti-affinity to work"""
    nodes = core_v1.list_node()

    zones_found = set()
    for node in nodes.items:
        zone = (
            node.metadata.labels.get('topology.kubernetes.io/zone') or
            node.metadata.labels.get('failure-domain.beta.kubernetes.io/zone')
        )
        if zone:
            zones_found.add(zone)

    console.print(f"[cyan]Nodes with zone labels:[/cyan] {len(zones_found)} zones")

    assert len(zones_found) > 0, \
        "No nodes have zone labels - anti-affinity rules cannot work"

    assert len(zones_found) >= 2, \
        f"Only {len(zones_found)} zone(s) found - need at least 2 for multi-AZ deployment"

"""
Test that PXC pods are distributed across availability zones
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pods_distributed_across_zones(core_v1):
    """Test that PXC pods are distributed across availability zones"""
    pods = core_v1.list_namespaced_pod(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    assert len(pods.items) >= 1, \
        f"Expected at least 1 PXC pod, found {len(pods.items)}"

    # Get zones for each pod
    zones = {}
    for pod in pods.items:
        if not pod.spec.node_name:
            continue

        # Get node to find zone
        node = core_v1.read_node(name=pod.spec.node_name)
        zone = (
            node.metadata.labels.get('topology.kubernetes.io/zone') or
            node.metadata.labels.get('failure-domain.beta.kubernetes.io/zone') or
            'unknown'
        )

        if zone not in zones:
            zones[zone] = []
        zones[zone].append(pod.metadata.name)

    console.print(f"[cyan]PXC Pod Distribution:[/cyan] {len(zones)} zones")
    for zone, pod_names in zones.items():
        console.print(f"  Zone {zone}: {len(pod_names)} pod(s)")

    # Verify pods are distributed (each zone should have at most 1 pod)
    for zone, pod_names in zones.items():
        assert len(pod_names) <= 1, \
            f"Multiple PXC pods in same zone {zone}: {pod_names} (anti-affinity violation)"

    # Verify we have pods in multiple zones/nodes (anti-affinity is working)
    # Note: If using hostname-based anti-affinity, each pod should be on a different node
    # If using zone-based anti-affinity, each pod should be in a different zone
    # We require pods to be distributed (each zone should have at most 1 pod, which is already checked above)
    # And we should have at least min(actual_pod_count, 3) unique placements
    actual_pod_count = len(pods.items)
    min_expected = min(actual_pod_count, 3)
    assert len(zones) >= min_expected, \
        f"PXC pods not distributed across enough zones/nodes: {len(zones)} unique placements for {actual_pod_count} pod(s), expected at least {min_expected}"

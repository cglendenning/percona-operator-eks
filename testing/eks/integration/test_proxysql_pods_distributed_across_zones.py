"""
Test that ProxySQL pods are distributed across availability zones
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_pods_distributed_across_zones(core_v1):
    """Test that ProxySQL pods are distributed across availability zones"""
    pods = core_v1.list_namespaced_pod(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=proxysql'
    )

    assert len(pods.items) > 0, "No ProxySQL pods found"

    # Get zones for each pod
    zones = {}
    for pod in pods.items:
        if not pod.spec.node_name:
            continue

        node = core_v1.read_node(name=pod.spec.node_name)
        zone = (
            node.metadata.labels.get('topology.kubernetes.io/zone') or
            node.metadata.labels.get('failure-domain.beta.kubernetes.io/zone') or
            'unknown'
        )

        if zone not in zones:
            zones[zone] = []
        zones[zone].append(pod.metadata.name)

    console.print(f"[cyan]ProxySQL Pod Distribution:[/cyan] {len(zones)} zones")
    for zone, pod_names in zones.items():
        console.print(f"  Zone {zone}: {len(pod_names)} pod(s)")

    # Verify pods are distributed (each zone should have at most 1 pod)
    for zone, pod_names in zones.items():
        assert len(pod_names) <= 1, \
            f"Multiple ProxySQL pods in same zone {zone}: {pod_names} (anti-affinity violation)"


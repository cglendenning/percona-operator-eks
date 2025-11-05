"""
Test that ProxySQL StatefulSet has anti-affinity rules
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_anti_affinity_rules(apps_v1):
    """Test that ProxySQL StatefulSet has anti-affinity rules"""
    # Get all StatefulSets and find ProxySQL by name pattern
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    proxysql_sts = [sts for sts in sts_list.items if 'proxysql' in sts.metadata.name]

    assert len(proxysql_sts) > 0, "ProxySQL StatefulSet not found"

    sts = proxysql_sts[0]
    affinity = sts.spec.template.spec.affinity

    assert affinity is not None, "ProxySQL StatefulSet should have affinity rules"

    pod_anti_affinity = affinity.pod_anti_affinity
    assert pod_anti_affinity is not None, \
        "ProxySQL StatefulSet should have podAntiAffinity rules"

    required = pod_anti_affinity.required_during_scheduling_ignored_during_execution
    assert required is not None and len(required) > 0, \
        "ProxySQL should have requiredDuringSchedulingIgnoredDuringExecution anti-affinity rules"

    # Verify topologyKey
    for term in required:
        topology_key = term.topology_key
        console.print(f"[cyan]ProxySQL Anti-affinity TopologyKey:[/cyan] {topology_key}")
        # Accept zone-based or hostname-based topology keys
        assert 'zone' in topology_key.lower() or 'hostname' in topology_key.lower(), \
            f"ProxySQL anti-affinity topologyKey should contain 'zone' or 'hostname', got: {topology_key}"

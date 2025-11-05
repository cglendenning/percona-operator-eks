"""
Test that PXC StatefulSet has anti-affinity rules
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_anti_affinity_rules(apps_v1):
    """Test that PXC StatefulSet has anti-affinity rules"""
    # Get all StatefulSets and find PXC by name pattern
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    pxc_sts = [sts for sts in sts_list.items if '-pxc' in sts.metadata.name and 'proxysql' not in sts.metadata.name]

    assert len(pxc_sts) > 0, "PXC StatefulSet not found"

    sts = pxc_sts[0]
    affinity = sts.spec.template.spec.affinity

    assert affinity is not None, "PXC StatefulSet should have affinity rules"

    pod_anti_affinity = affinity.pod_anti_affinity
    assert pod_anti_affinity is not None, \
        "PXC StatefulSet should have podAntiAffinity rules"

    # Check requiredDuringSchedulingIgnoredDuringExecution
    required = pod_anti_affinity.required_during_scheduling_ignored_during_execution
    assert required is not None and len(required) > 0, \
        "PXC should have requiredDuringSchedulingIgnoredDuringExecution anti-affinity rules"

    # Verify topologyKey is zone-based or hostname-based
    for term in required:
        label_selector = term.label_selector
        topology_key = term.topology_key

        console.print(f"[cyan]Anti-affinity TopologyKey:[/cyan] {topology_key}")
        # Accept zone-based or hostname-based topology keys
        # hostname ensures pods on different nodes, zone ensures pods in different AZs
        assert 'zone' in topology_key.lower() or 'hostname' in topology_key.lower(), \
            f"Anti-affinity topologyKey should contain 'zone' or 'hostname', got: {topology_key}"

        # Verify label selector matches PXC component
        if label_selector.match_expressions:
            for expr in label_selector.match_expressions:
                if expr.key == 'app.kubernetes.io/component' and expr.operator == 'In':
                    assert 'pxc' in str(expr.values).lower(), \
                        "Anti-affinity should match PXC component label"

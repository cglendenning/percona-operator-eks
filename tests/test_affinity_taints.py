"""
Test Anti-affinity rules, taints, and tolerations
"""
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES

console = Console()


class TestAntiAffinity:
    """Test pod anti-affinity rules"""

    def test_pxc_anti_affinity_rules(self, apps_v1):
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

    def test_proxysql_anti_affinity_rules(self, apps_v1):
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

    def test_pods_distributed_across_zones(self, core_v1):
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

    def test_proxysql_pods_distributed_across_zones(self, core_v1):
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


class TestTaintsAndTolerations:
    """Test taints and tolerations"""

    def test_nodes_have_zone_labels(self, core_v1):
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

    def test_pods_can_have_tolerations(self, apps_v1):
        """Test that StatefulSet pod templates can have tolerations (optional check)"""
        sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
        
        for sts in sts_list.items:
            tolerations = sts.spec.template.spec.tolerations or []
            console.print(f"[cyan]{sts.metadata.name} Tolerations:[/cyan] {len(tolerations)}")
            # Tolerations are optional, so we just log them


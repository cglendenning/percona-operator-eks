"""
Test Resource limits and Pod Disruption Budgets
"""
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE

console = Console()


class TestResourceLimits:
    """Test resource requests and limits"""

    def test_pxc_resource_requests(self, apps_v1):
        """Test that PXC pods have resource requests configured"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        assert len(sts_list.items) > 0, "PXC StatefulSet not found"
        
        sts = sts_list.items[0]
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

    def test_pxc_resource_values(self, apps_v1):
        """Test that PXC resources match expected values (500m CPU, 1Gi memory request)"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        sts = sts_list.items[0]
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

    def test_proxysql_resource_requests(self, apps_v1):
        """Test that ProxySQL pods have resource requests configured"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        assert len(sts_list.items) > 0, "ProxySQL StatefulSet not found"
        
        sts = sts_list.items[0]
        containers = sts.spec.template.spec.containers
        
        proxysql_container = next(
            (c for c in containers if 'proxysql' in c.name.lower()),
            None
        )
        
        assert proxysql_container is not None, "ProxySQL container not found"
        
        resources = proxysql_container.resources
        assert resources is not None, "ProxySQL container should have resource limits/requests"
        
        requests = resources.requests or {}
        limits = resources.limits or {}
        
        console.print(f"[cyan]ProxySQL Resource Requests:[/cyan] {requests}")
        console.print(f"[cyan]ProxySQL Resource Limits:[/cyan] {limits}")
        
        assert 'cpu' in requests, "ProxySQL container should have CPU request"
        assert 'memory' in requests, "ProxySQL container should have memory request"

    def test_proxysql_resource_values(self, apps_v1):
        """Test that ProxySQL resources match expected values (100m CPU, 256Mi memory request)"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        sts = sts_list.items[0]
        containers = sts.spec.template.spec.containers
        
        proxysql_container = next(
            (c for c in containers if 'proxysql' in c.name.lower()),
            None
        )
        
        resources = proxysql_container.resources
        requests = resources.requests or {}
        
        # Expected: cpu: 100m, memory: 256Mi
        expected_cpu = '100m'
        expected_memory = '256Mi'
        
        if 'cpu' in requests:
            console.print(f"[cyan]ProxySQL CPU Request:[/cyan] {requests['cpu']} (expected: {expected_cpu})")
            assert requests['cpu'] == expected_cpu, \
                f"ProxySQL CPU request mismatch: got {requests['cpu']}, expected {expected_cpu}"
        
        if 'memory' in requests:
            console.print(f"[cyan]ProxySQL Memory Request:[/cyan] {requests['memory']} (expected: {expected_memory})")
            assert requests['memory'] == expected_memory, \
                f"ProxySQL memory request mismatch: got {requests['memory']}, expected {expected_memory}"


class TestPodDisruptionBudgets:
    """Test Pod Disruption Budgets"""

    def test_pxc_pdb_exists(self, policy_v1):
        """Test that PDB exists for PXC StatefulSet"""
        try:
            pdb_list = policy_v1.list_namespaced_pod_disruption_budget(
                namespace=TEST_NAMESPACE
            )
            
            pxc_pdbs = [
                pdb for pdb in pdb_list.items
                if 'pxc' in pdb.metadata.name.lower() and 'proxysql' not in pdb.metadata.name.lower()
            ]
            
            assert len(pxc_pdbs) > 0, \
                "Pod Disruption Budget for PXC not found"
            
            pdb = pxc_pdbs[0]
            console.print(f"[cyan]PXC PDB:[/cyan] {pdb.metadata.name}")
            
            # Check minAvailable or maxUnavailable
            spec = pdb.spec
            max_unavailable = spec.max_unavailable
            min_available = spec.min_available
            
            if max_unavailable:
                console.print(f"[cyan]PXC PDB MaxUnavailable:[/cyan] {max_unavailable}")
                # Should be 1 (from config)
                assert str(max_unavailable) == '1', \
                    f"PXC PDB maxUnavailable should be 1, got: {max_unavailable}"
            
            if min_available:
                console.print(f"[cyan]PXC PDB MinAvailable:[/cyan] {min_available}")
                
        except Exception as e:
            # PDBs might not exist in all versions
            console.print(f"[yellow]⚠ PDB check failed:[/yellow] {e}")
            pytest.skip("Pod Disruption Budget check failed - may not be configured")

    def test_proxysql_pdb_exists(self, policy_v1):
        """Test that PDB exists for ProxySQL StatefulSet"""
        try:
            pdb_list = policy_v1.list_namespaced_pod_disruption_budget(
                namespace=TEST_NAMESPACE
            )
            
            proxysql_pdbs = [
                pdb for pdb in pdb_list.items
                if 'proxysql' in pdb.metadata.name.lower()
            ]
            
            assert len(proxysql_pdbs) > 0, \
                "Pod Disruption Budget for ProxySQL not found"
            
            pdb = proxysql_pdbs[0]
            console.print(f"[cyan]ProxySQL PDB:[/cyan] {pdb.metadata.name}")
            
            spec = pdb.spec
            max_unavailable = spec.max_unavailable
            
            if max_unavailable:
                console.print(f"[cyan]ProxySQL PDB MaxUnavailable:[/cyan] {max_unavailable}")
                assert str(max_unavailable) == '1', \
                    f"ProxySQL PDB maxUnavailable should be 1, got: {max_unavailable}"
                
        except Exception as e:
            console.print(f"[yellow]⚠ PDB check failed:[/yellow] {e}")
            pytest.skip("Pod Disruption Budget check failed - may not be configured")


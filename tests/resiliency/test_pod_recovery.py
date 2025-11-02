"""
Resiliency tests for pod recovery after chaos events
"""
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from tests.resiliency.helpers import (
    wait_for_pod_recovery,
    wait_for_statefulset_recovery,
    wait_for_service_recovery,
    wait_for_cluster_recovery,
    DEFAULT_MTTR_TIMEOUT
)

console = Console()


@pytest.mark.resiliency
class TestPodRecovery:
    """Test pod recovery after chaos events"""
    
    def test_pxc_pod_recovery(self, core_v1):
        """Test that PXC pods recover after being deleted"""
        # This test is typically triggered by LitmusChaos
        # For manual testing, we'd need to know which pod was deleted
        pytest.skip("Use LitmusChaos integration to trigger this test after pod-delete experiment")
    
    def test_proxysql_pod_recovery(self, core_v1):
        """Test that ProxySQL pods recover after being deleted"""
        pytest.skip("Use LitmusChaos integration to trigger this test after pod-delete experiment")


@pytest.mark.resiliency
class TestStatefulSetRecovery:
    """Test StatefulSet recovery after chaos events"""
    
    def test_pxc_statefulset_recovery(
        self,
        apps_v1,
        core_v1,
        custom_objects_v1,
        request
    ):
        """Test that PXC StatefulSet recovers after pod deletion"""
        # Get StatefulSet name
        from tests.conftest import TEST_CLUSTER_NAME
        sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
        pxc_sts = [sts for sts in sts_list.items if '-pxc' in sts.metadata.name and 'proxysql' not in sts.metadata.name]
        
        if not pxc_sts:
            pytest.skip("PXC StatefulSet not found")
        
        sts_name = pxc_sts[0].metadata.name
        expected_replicas = pxc_sts[0].spec.replicas
        
        # Check if this test was triggered by chaos (check for chaos marker)
        mttr_timeout = getattr(request.config, 'option', {}).get('mttr_timeout', DEFAULT_MTTR_TIMEOUT)
        
        console.print(f"[cyan]Testing PXC StatefulSet recovery: {sts_name}[/cyan]")
        wait_for_statefulset_recovery(
            apps_v1,
            TEST_NAMESPACE,
            sts_name,
            expected_replicas,
            timeout_seconds=mttr_timeout
        )
    
    def test_proxysql_statefulset_recovery(self, apps_v1, request):
        """Test that ProxySQL StatefulSet recovers after pod deletion"""
        sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
        proxysql_sts = [sts for sts in sts_list.items if 'proxysql' in sts.metadata.name]
        
        if not proxysql_sts:
            pytest.skip("ProxySQL StatefulSet not found")
        
        sts_name = proxysql_sts[0].metadata.name
        expected_replicas = proxysql_sts[0].spec.replicas
        
        mttr_timeout = getattr(request.config, 'option', {}).get('mttr_timeout', DEFAULT_MTTR_TIMEOUT)
        
        console.print(f"[cyan]Testing ProxySQL StatefulSet recovery: {sts_name}[/cyan]")
        wait_for_statefulset_recovery(
            apps_v1,
            TEST_NAMESPACE,
            sts_name,
            expected_replicas,
            timeout_seconds=mttr_timeout
        )


@pytest.mark.resiliency
class TestServiceRecovery:
    """Test service recovery after chaos events"""
    
    def test_pxc_service_recovery(self, core_v1, request):
        """Test that PXC service endpoints recover after pod deletion"""
        services = core_v1.list_namespaced_service(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        if not services.items:
            pytest.skip("PXC service not found")
        
        service_name = services.items[0].metadata.name
        mttr_timeout = getattr(request.config, 'option', {}).get('mttr_timeout', DEFAULT_MTTR_TIMEOUT)
        
        console.print(f"[cyan]Testing PXC service recovery: {service_name}[/cyan]")
        wait_for_service_recovery(
            core_v1,
            TEST_NAMESPACE,
            service_name,
            min_endpoints=1,
            timeout_seconds=mttr_timeout
        )
    
    def test_proxysql_service_recovery(self, core_v1, request):
        """Test that ProxySQL service endpoints recover after pod deletion"""
        services = core_v1.list_namespaced_service(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        if not services.items:
            pytest.skip("ProxySQL service not found")
        
        service_name = services.items[0].metadata.name
        mttr_timeout = getattr(request.config, 'option', {}).get('mttr_timeout', DEFAULT_MTTR_TIMEOUT)
        
        console.print(f"[cyan]Testing ProxySQL service recovery: {service_name}[/cyan]")
        wait_for_service_recovery(
            core_v1,
            TEST_NAMESPACE,
            service_name,
            min_endpoints=1,
            timeout_seconds=mttr_timeout
        )


@pytest.mark.resiliency
class TestClusterRecovery:
    """Test cluster-level recovery after chaos events"""
    
    def test_cluster_status_recovery(self, custom_objects_v1, request):
        """Test that cluster status recovers to ready after chaos"""
        from tests.conftest import TEST_CLUSTER_NAME
        
        cluster_name = f'{TEST_CLUSTER_NAME}-pxc-db'
        mttr_timeout = getattr(request.config, 'option', {}).get('mttr_timeout', DEFAULT_MTTR_TIMEOUT)
        
        console.print(f"[cyan]Testing cluster recovery: {cluster_name}[/cyan]")
        wait_for_cluster_recovery(
            custom_objects_v1,
            TEST_NAMESPACE,
            cluster_name,
            TEST_EXPECTED_NODES,
            timeout_seconds=mttr_timeout
        )


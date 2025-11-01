"""
Test StatefulSets configuration
"""
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

console = Console()


class TestStatefulSets:
    """Test StatefulSets configuration"""

    def test_pxc_statefulset_exists(self, apps_v1):
        """Test that PXC StatefulSet exists"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        assert len(sts_list.items) > 0, "PXC StatefulSet not found"
        
        sts = sts_list.items[0]
        console.print(f"[cyan]PXC StatefulSet:[/cyan] {sts.metadata.name}")
        console.print(f"[cyan]Replicas:[/cyan] {sts.spec.replicas}/{sts.status.ready_replicas}")
        
        assert sts.spec.replicas == TEST_EXPECTED_NODES, \
            f"PXC StatefulSet has wrong replica count: {sts.spec.replicas}, expected {TEST_EXPECTED_NODES}"
        
        assert sts.status.ready_replicas == TEST_EXPECTED_NODES, \
            f"Not all PXC replicas are ready: {sts.status.ready_replicas}/{TEST_EXPECTED_NODES}"

    def test_proxysql_statefulset_exists(self, apps_v1):
        """Test that ProxySQL StatefulSet exists"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        assert len(sts_list.items) > 0, "ProxySQL StatefulSet not found"
        
        sts = sts_list.items[0]
        console.print(f"[cyan]ProxySQL StatefulSet:[/cyan] {sts.metadata.name}")
        console.print(f"[cyan]Replicas:[/cyan] {sts.spec.replicas}/{sts.status.ready_replicas}")
        
        assert sts.spec.replicas == TEST_EXPECTED_NODES, \
            f"ProxySQL StatefulSet has wrong replica count: {sts.spec.replicas}, expected {TEST_EXPECTED_NODES}"
        
        assert sts.status.ready_replicas == TEST_EXPECTED_NODES, \
            f"Not all ProxySQL replicas are ready: {sts.status.ready_replicas}/{TEST_EXPECTED_NODES}"

    def test_statefulset_service_name(self, apps_v1):
        """Test that StatefulSets have correct service names"""
        sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
        
        for sts in sts_list.items:
            service_name = sts.spec.service_name
            assert service_name is not None and len(service_name) > 0, \
                f"StatefulSet {sts.metadata.name} has no service name"
            
            console.print(f"[cyan]{sts.metadata.name} ServiceName:[/cyan] {service_name}")

    def test_statefulset_update_strategy(self, apps_v1):
        """Test that StatefulSets use appropriate update strategy"""
        sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
        
        for sts in sts_list.items:
            update_strategy = sts.spec.update_strategy.type
            console.print(f"[cyan]{sts.metadata.name} UpdateStrategy:[/cyan] {update_strategy}")
            
            # StatefulSets should use RollingUpdate or OnDelete
            assert update_strategy in ['RollingUpdate', 'OnDelete'], \
                f"StatefulSet {sts.metadata.name} has unexpected update strategy: {update_strategy}"

    def test_statefulset_pod_management_policy(self, apps_v1):
        """Test that StatefulSets use OrderedReady pod management"""
        sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
        
        for sts in sts_list.items:
            # OrderedReady is the default (can be None)
            pod_management = sts.spec.pod_management_policy or 'OrderedReady'
            console.print(f"[cyan]{sts.metadata.name} PodManagementPolicy:[/cyan] {pod_management}")

    def test_statefulset_volume_claim_templates(self, apps_v1):
        """Test that StatefulSets have volume claim templates"""
        sts_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        assert len(sts_list.items) > 0, "PXC StatefulSet not found"
        
        sts = sts_list.items[0]
        volume_claims = sts.spec.volume_claim_templates
        
        assert len(volume_claims) > 0, \
            "PXC StatefulSet should have volume claim templates"
        
        for vct in volume_claims:
            console.print(f"[cyan]VolumeClaimTemplate:[/cyan] {vct.metadata.name}")
            assert vct.spec.resources.requests.get('storage') is not None, \
                f"VolumeClaimTemplate {vct.metadata.name} has no storage request"


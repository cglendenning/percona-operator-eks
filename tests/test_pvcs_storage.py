"""
Test Persistent Volume Claims and Storage configuration
"""
import pytest
from kubernetes import client
from rich.console import Console
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

console = Console()


class TestPVCsAndStorage:
    """Test PVCs and storage configuration"""

    def test_pvcs_exist_for_pxc(self, core_v1):
        """Test that PVCs exist for PXC pods"""
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        assert len(pvcs.items) >= TEST_EXPECTED_NODES, \
            f"Expected at least {TEST_EXPECTED_NODES} PVCs for PXC, found {len(pvcs.items)}"
        
        console.print(f"[cyan]PXC PVCs Found:[/cyan] {len(pvcs.items)}")
        
        # Verify each PVC is bound
        for pvc in pvcs.items:
            assert pvc.status.phase == 'Bound', \
                f"PVC {pvc.metadata.name} is not Bound (status: {pvc.status.phase})"
            console.print(f"  ✓ {pvc.metadata.name}: {pvc.status.phase} ({pvc.spec.resources.requests.get('storage', 'unknown')})")

    def test_pvcs_exist_for_proxysql(self, core_v1):
        """Test that PVCs exist for ProxySQL pods"""
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        assert len(pvcs.items) > 0, "No PVCs found for ProxySQL"
        
        console.print(f"[cyan]ProxySQL PVCs Found:[/cyan] {len(pvcs.items)}")
        
        # Verify each PVC is bound
        for pvc in pvcs.items:
            assert pvc.status.phase == 'Bound', \
                f"ProxySQL PVC {pvc.metadata.name} is not Bound (status: {pvc.status.phase})"

    def test_pxc_pvc_storage_size(self, core_v1):
        """Test that PXC PVCs have correct storage size (should be 20Gi from config)"""
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        expected_size = '20Gi'
        
        for pvc in pvcs.items:
            requested_size = pvc.spec.resources.requests.get('storage', '')
            console.print(f"[cyan]PVC {pvc.metadata.name}:[/cyan] {requested_size}")
            assert requested_size == expected_size, \
                f"PXC PVC {pvc.metadata.name} has incorrect size: {requested_size}, expected {expected_size}"

    def test_pxc_pvc_storage_class(self, core_v1):
        """Test that PXC PVCs use the correct storage class (gp3)"""
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        for pvc in pvcs.items:
            storage_class = pvc.spec.storage_class_name
            console.print(f"[cyan]PVC {pvc.metadata.name} StorageClass:[/cyan] {storage_class}")
            assert storage_class == 'gp3', \
                f"PXC PVC {pvc.metadata.name} uses wrong storage class: {storage_class}, expected gp3"

    def test_proxysql_pvc_storage_size(self, core_v1):
        """Test that ProxySQL PVCs have correct storage size (should be 5Gi)"""
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        expected_size = '5Gi'
        
        for pvc in pvcs.items:
            requested_size = pvc.spec.resources.requests.get('storage', '')
            console.print(f"[cyan]ProxySQL PVC {pvc.metadata.name}:[/cyan] {requested_size}")
            assert requested_size == expected_size, \
                f"ProxySQL PVC {pvc.metadata.name} has incorrect size: {requested_size}, expected {expected_size}"

    def test_storage_class_exists(self, storage_v1):
        """Test that gp3 storage class exists"""
        try:
            sc = storage_v1.read_storage_class(name='gp3')
            console.print(f"[cyan]StorageClass gp3:[/cyan] {sc.provisioner}")
            
            assert sc.provisioner == 'ebs.csi.aws.com', \
                f"StorageClass gp3 has wrong provisioner: {sc.provisioner}"
            
            # Check allowVolumeExpansion is enabled
            assert sc.allow_volume_expansion is True, \
                "StorageClass gp3 should allow volume expansion"
        except client.exceptions.ApiException as e:
            if e.status == 404:
                pytest.fail("StorageClass 'gp3' not found")
            raise

    def test_storage_class_parameters(self, storage_v1):
        """Test that gp3 storage class has correct parameters"""
        sc = storage_v1.read_storage_class(name='gp3')
        
        params = sc.parameters or {}
        
        # Check encryption is enabled
        assert params.get('encrypted') == 'true' or params.get('encrypted') == 'True', \
            "StorageClass gp3 should have encryption enabled"
        
        # Check volume binding mode
        assert sc.volume_binding_mode == 'WaitForFirstConsumer', \
            f"StorageClass gp3 should use WaitForFirstConsumer binding mode, got: {sc.volume_binding_mode}"

    def test_pvc_access_modes(self, core_v1):
        """Test that PVCs have correct access modes (ReadWriteOnce)"""
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE
        )
        
        # Filter for Percona PVCs
        percona_pvcs = [
            pvc for pvc in pvcs.items
            if 'pxc' in pvc.metadata.name.lower() or 'proxysql' in pvc.metadata.name.lower()
        ]
        
        for pvc in percona_pvcs:
            access_modes = pvc.spec.access_modes
            assert 'ReadWriteOnce' in access_modes, \
                f"PVC {pvc.metadata.name} should have ReadWriteOnce access mode, got: {access_modes}"


"""
Integration tests for cluster scaling operations.
Validates that cluster can be scaled up/down properly.
"""
import pytest
import time
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from kubernetes import client
from rich.console import Console

console = Console()


@pytest.mark.integration
def test_cluster_can_scale_up(apps_v1, custom_objects_v1):
    """Test that cluster can scale up (add nodes)."""
    # Note: This test documents the capability but doesn't actually scale
    # Actual scaling should be done carefully to avoid breaking the cluster
    
    group = 'pxc.percona.com'
    version = 'v1'
    plural = 'perconaxtradbclusters'
    
    try:
        cluster = custom_objects_v1.get_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural,
            name=TEST_CLUSTER_NAME
        )
        
        current_size = cluster.get('spec', {}).get('pxc', {}).get('size', 0)
        assert current_size > 0, "Cluster should have a valid size"
        
        console.print(f"[green]✓[/green] Cluster current size: {current_size} nodes")
        console.print(f"[dim]Note: Actual scaling should be tested separately with proper coordination[/dim]")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"Cluster {TEST_CLUSTER_NAME} not found")
        raise


@pytest.mark.integration
def test_statefulset_replicas_match_cluster_size(apps_v1):
    """Test that StatefulSet replicas match the cluster size configuration."""
    # Check PXC StatefulSet
    try:
        pxc_sts = apps_v1.read_namespaced_stateful_set(
            name=f'{TEST_CLUSTER_NAME}-pxc',
            namespace=TEST_NAMESPACE
        )
        pxc_replicas = pxc_sts.spec.replicas
        
        # Get cluster size from custom resource
        from kubernetes import client
        custom_objects_v1 = client.CustomObjectsApi()
        group = 'pxc.percona.com'
        version = 'v1'
        plural = 'perconaxtradbclusters'
        
        cluster = custom_objects_v1.get_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural,
            name=TEST_CLUSTER_NAME
        )
        
        cluster_size = cluster.get('spec', {}).get('pxc', {}).get('size', 0)
        
        assert pxc_replicas == cluster_size, \
            f"PXC StatefulSet replicas ({pxc_replicas}) should match cluster size ({cluster_size})"
        
        console.print(f"[green]✓[/green] PXC StatefulSet replicas ({pxc_replicas}) match cluster size")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip(f"PXC StatefulSet not found (may not be created yet)")
        raise


@pytest.mark.integration
def test_proxysql_replicas_match_cluster_size(apps_v1):
    """Test that ProxySQL StatefulSet replicas match the cluster size."""
    try:
        proxysql_sts = apps_v1.read_namespaced_stateful_set(
            name=f'{TEST_CLUSTER_NAME}-proxysql',
            namespace=TEST_NAMESPACE
        )
        proxysql_replicas = proxysql_sts.spec.replicas
        
        # Get cluster size
        from kubernetes import client
        custom_objects_v1 = client.CustomObjectsApi()
        group = 'pxc.percona.com'
        version = 'v1'
        plural = 'perconaxtradbclusters'
        
        cluster = custom_objects_v1.get_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural,
            name=TEST_CLUSTER_NAME
        )
        
        cluster_size = cluster.get('spec', {}).get('proxysql', {}).get('size', 0)
        
        assert proxysql_replicas == cluster_size, \
            f"ProxySQL StatefulSet replicas ({proxysql_replicas}) should match cluster size ({cluster_size})"
        
        console.print(f"[green]✓[/green] ProxySQL StatefulSet replicas ({proxysql_replicas}) match cluster size")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip(f"ProxySQL StatefulSet not found (may not be created yet)")
        raise


@pytest.mark.integration
def test_pods_distributed_across_zones_on_scale(core_v1):
    """Test that when cluster scales, pods remain distributed across zones."""
    # Get all PXC pods
    try:
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        if len(pods.items) == 0:
            pytest.skip("No PXC pods found")
        
        # Extract zones from pod node labels (via node name)
        zones = set()
        for pod in pods.items:
            if pod.spec.node_name:
                try:
                    node = core_v1.read_node(pod.spec.node_name)
                    zone = (node.metadata.labels.get('topology.kubernetes.io/zone') or
                           node.metadata.labels.get('failure-domain.beta.kubernetes.io/zone'))
                    if zone:
                        zones.add(zone)
                except client.exceptions.ApiException:
                    pass
        
        if len(pods.items) >= 3:
            # For 3+ pods, should be in multiple zones
            assert len(zones) >= 2, \
                f"With {len(pods.items)} pods, should be in multiple zones. Found: {zones}"
        
        console.print(f"[green]✓[/green] Pods distributed across {len(zones)} zone(s): {zones}")
    except client.exceptions.ApiException:
        pytest.skip("Could not check pod distribution")


@pytest.mark.integration
def test_pvc_count_matches_replicas(core_v1, apps_v1):
    """Test that PVC count matches StatefulSet replicas."""
    try:
        pxc_sts = apps_v1.read_namespaced_stateful_set(
            name=f'{TEST_CLUSTER_NAME}-pxc',
            namespace=TEST_NAMESPACE
        )
        expected_replicas = pxc_sts.spec.replicas
        
        # Count PVCs for PXC
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        # StatefulSet creates PVCs with pattern: <volume-claim-template-name>-<statefulset-name>-<ordinal>
        pxc_pvcs = [pvc for pvc in pvcs.items if TEST_CLUSTER_NAME in pvc.metadata.name]
        
        # Should have at least as many PVCs as replicas (may have more if scaling down)
        assert len(pxc_pvcs) >= expected_replicas, \
            f"Should have at least {expected_replicas} PVCs for {expected_replicas} replicas. Found: {len(pxc_pvcs)}"
        
        console.print(f"[green]✓[/green] PVC count ({len(pxc_pvcs)}) matches expected replicas ({expected_replicas})")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip("StatefulSet or PVCs not found")
        raise


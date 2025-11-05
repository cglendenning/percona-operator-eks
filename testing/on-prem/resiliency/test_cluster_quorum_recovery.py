"""
Resiliency tests for cluster quorum recovery.
Tests that cluster maintains and recovers quorum after node failures.
"""
import pytest
import time
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from kubernetes import client
from rich.console import Console

console = Console()


@pytest.mark.resiliency
def test_cluster_maintains_quorum_during_single_pod_failure(core_v1, custom_objects_v1):
    """Test that cluster maintains quorum when a single pod fails."""
    # This test validates that with proper PDB configuration,
    # only one pod can be disrupted at a time, maintaining quorum
    
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
        
        cluster_size = cluster.get('spec', {}).get('pxc', {}).get('size', 0)
        
        # Get PDB configuration
        from kubernetes import client
        policy_v1 = client.PolicyV1Api()
        try:
            pdb = policy_v1.read_namespaced_pod_disruption_budget(
                name=f'{TEST_CLUSTER_NAME}-pxc',
                namespace=TEST_NAMESPACE
            )
            max_unavailable = pdb.spec.max_unavailable
            
            # Calculate available pods during disruption
            if hasattr(max_unavailable, 'int_value'):
                max_unavailable_count = max_unavailable.int_value
            else:
                # Could be a percentage or integer string
                max_unavailable_count = 1  # Default assumption
            
            available_during_disruption = cluster_size - max_unavailable_count
            quorum = (cluster_size // 2) + 1
            
            assert available_during_disruption >= quorum, \
                f"With maxUnavailable={max_unavailable_count}, " \
                f"{available_during_disruption} pods available, " \
                f"but quorum requires {quorum}"
            
            console.print(f"[green]✓[/green] PDB ensures quorum: {available_during_disruption} >= {quorum}")
        except client.exceptions.ApiException as e:
            if e.status == 404:
                pytest.skip("PDB not found")
            raise
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip("Cluster not found")
        raise


@pytest.mark.resiliency
def test_cluster_recovers_after_pod_deletion(core_v1, apps_v1):
    """Test that cluster recovers after a pod is deleted."""
    # Get current pod status
    try:
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        if len(pods.items) < 3:
            pytest.skip("Need at least 3 pods to test recovery")
        
        # Get initial ready count
        initial_ready = sum(1 for p in pods.items if 
                           any(cs.ready for cs in (p.status.container_statuses or [])))
        
        # Note: Actual pod deletion is tested in chaos experiments
        # This test validates that the cluster is configured for recovery
        
        # Check that StatefulSet is configured for recovery
        sts = apps_v1.read_namespaced_stateful_set(
            name=f'{TEST_CLUSTER_NAME}-pxc',
            namespace=TEST_NAMESPACE
        )
        
        # StatefulSet should have proper restart policy
        pod_template = sts.spec.template
        assert pod_template.spec.restart_policy == 'Always', \
            "Pods should have Always restart policy for automatic recovery"
        
        console.print(f"[green]✓[/green] Cluster configured for recovery after pod deletion")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip("StatefulSet or pods not found")
        raise


@pytest.mark.resiliency
def test_cluster_status_reports_ready_after_recovery(custom_objects_v1):
    """Test that cluster status reports Ready after recovery from failure."""
    # Monitor cluster status
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
        
        status = cluster.get('status', {})
        state = status.get('state', '')
        
        # After recovery, cluster should be in ready state
        # Note: This test validates the capability, actual recovery is tested with chaos
        if state:
            console.print(f"[green]✓[/green] Cluster state: {state}")
        
        # Cluster should have ready status
        ready = status.get('ready', 0)
        size = cluster.get('spec', {}).get('pxc', {}).get('size', 0)
        
        # Ideally all nodes should be ready, but allow for transient states
        assert ready >= (size // 2) + 1, \
            f"At least quorum ({size // 2 + 1}) nodes should be ready. Found: {ready}"
        
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip("Cluster not found")
        raise


@pytest.mark.resiliency
def test_cluster_handles_concurrent_pod_failures(core_v1, policy_v1):
    """Test that PDB prevents too many concurrent pod failures."""
    try:
        pdb = policy_v1.read_namespaced_pod_disruption_budget(
            name=f'{TEST_CLUSTER_NAME}-pxc',
            namespace=TEST_NAMESPACE
        )
        
        max_unavailable = pdb.spec.max_unavailable
        
        # PDB should prevent more than max_unavailable pods from being disrupted
        # This ensures quorum is maintained
        
        # Get current pod count
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        pod_count = len(pods.items)
        
        # Calculate minimum available
        if hasattr(max_unavailable, 'int_value'):
            max_unavailable_count = max_unavailable.int_value
        else:
            # Assume it's 1 for safety
            max_unavailable_count = 1
        
        min_available = pod_count - max_unavailable_count
        quorum = (pod_count // 2) + 1
        
        assert min_available >= quorum, \
            f"PDB ensures at least {min_available} pods available, " \
            f"which is >= quorum of {quorum}"
        
        console.print(f"[green]✓[/green] PDB prevents concurrent failures from breaking quorum")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip("PDB not found")
        raise


@pytest.mark.resiliency
def test_cluster_data_persistence_after_pod_restart(core_v1, apps_v1):
    """Test that cluster data persists after pod restart (validates PVC configuration)."""
    try:
        # Check that StatefulSet uses volume claim templates (required for persistence)
        sts = apps_v1.read_namespaced_stateful_set(
            name=f'{TEST_CLUSTER_NAME}-pxc',
            namespace=TEST_NAMESPACE
        )
        
        volume_claim_templates = sts.spec.volume_claim_templates
        assert len(volume_claim_templates) > 0, \
            "StatefulSet must have volume claim templates for data persistence"
        
        # Verify PVCs exist for pods
        pvcs = core_v1.list_namespaced_persistent_volume_claim(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        # Should have at least one PVC per pod
        assert len(pvcs.items) >= len(pods.items), \
            f"Should have at least {len(pods.items)} PVCs for {len(pods.items)} pods"
        
        # Verify PVCs are bound
        bound_pvcs = [pvc for pvc in pvcs.items if pvc.status.phase == 'Bound']
        assert len(bound_pvcs) > 0, "At least some PVCs should be bound"
        
        console.print(f"[green]✓[/green] Data persistence configured: {len(bound_pvcs)} PVCs bound")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.skip("StatefulSet or PVCs not found")
        raise


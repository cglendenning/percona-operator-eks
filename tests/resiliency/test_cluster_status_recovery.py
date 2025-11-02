"""
Test that cluster status recovers to ready after chaos
"""
import os
import time
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from tests.resiliency.helpers import (
    wait_for_cluster_recovery,
    DEFAULT_MTTR_TIMEOUT
)

console = Console()


@pytest.mark.resiliency
def test_cluster_status_recovery(custom_objects_v1, request):
    """Test that cluster status recovers to ready after chaos"""
    console.print("[bold cyan]Starting cluster status recovery test...[/bold cyan]")
    
    cluster_name = f'{TEST_CLUSTER_NAME}-pxc-db'
    
    # Check initial cluster status
    console.print(f"[dim]Reading cluster status for {cluster_name}...[/dim]")
    try:
        cr = custom_objects_v1.get_namespaced_custom_object(
            group='pxc.percona.com',
            version='v1',
            namespace=TEST_NAMESPACE,
            plural='perconaxtradbclusters',
            name=cluster_name
        )
        initial_state = cr.get('status', {}).get('state', 'unknown')
        initial_pxc_ready = cr.get('status', {}).get('pxc', {}).get('ready', 0) if isinstance(cr.get('status', {}).get('pxc'), dict) else 0
    except Exception as e:
        pytest.skip(f"Could not read cluster status: {e}")
    
    # Verify initial state
    console.print(f"[cyan]Initial state check: Cluster {cluster_name}[/cyan]")
    console.print(f"  Initial state: {initial_state}")
    console.print(f"  Initial PXC ready: {initial_pxc_ready}/{TEST_EXPECTED_NODES}")
    assert initial_state == 'ready', f"Expected cluster to be in 'ready' state, got '{initial_state}'"
    assert initial_pxc_ready >= TEST_EXPECTED_NODES, f"Expected at least {TEST_EXPECTED_NODES} PXC nodes ready, got {initial_pxc_ready}"
    console.print(f"[green]✓ Confirmed: Cluster {cluster_name} is ready with {initial_pxc_ready} PXC nodes[/green]")
    
    # Wait and check if cluster status was affected by chaos
    console.print(f"[cyan]Checking if cluster {cluster_name} was affected by chaos...[/cyan]")
    max_wait = 60
    start_time = time.time()
    cluster_broken = False
    check_count = 0
    
    while time.time() - start_time < max_wait:
        check_count += 1
        elapsed = int(time.time() - start_time)
        if check_count % 5 == 0 or check_count == 1:  # Print every 5th check or first check
            console.print(f"[dim]  Check #{check_count} at {elapsed}s: Monitoring cluster status...[/dim]")
        
        try:
            current_cr = custom_objects_v1.get_namespaced_custom_object(
                group='pxc.percona.com',
                version='v1',
                namespace=TEST_NAMESPACE,
                plural='perconaxtradbclusters',
                name=cluster_name
            )
            current_state = current_cr.get('status', {}).get('state', 'unknown')
            current_pxc_ready = current_cr.get('status', {}).get('pxc', {}).get('ready', 0) if isinstance(current_cr.get('status', {}).get('pxc'), dict) else 0
            
            if check_count % 5 == 0 or check_count == 1:  # Print status every 5th check
                console.print(f"[dim]    Current status: state={current_state}, PXC ready={current_pxc_ready}/{TEST_EXPECTED_NODES}[/dim]")
            
            if current_state != 'ready' or current_pxc_ready < TEST_EXPECTED_NODES:
                console.print(f"[yellow]⚠ Cluster {cluster_name} is broken: state={current_state}, PXC ready={current_pxc_ready}/{TEST_EXPECTED_NODES}[/yellow]")
                cluster_broken = True
                break
        except Exception as e:
            console.print(f"[yellow]⚠ Error checking cluster status: {e}[/yellow]")
        
        time.sleep(3)
    
    if not cluster_broken:
        console.print(f"[yellow]Note: Cluster {cluster_name} was not affected by chaos (may have already recovered)[/yellow]")
    
    try:
        mttr_timeout = getattr(request.config.option, 'mttr_timeout', None)
        if mttr_timeout is None:
            mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    except (AttributeError, ValueError):
        mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    
    # Verify recovery
    console.print(f"[cyan]Verifying recovery: Waiting for cluster {cluster_name} to recover...[/cyan]")
    wait_for_cluster_recovery(
        custom_objects_v1,
        TEST_NAMESPACE,
        cluster_name,
        TEST_EXPECTED_NODES,
        timeout_seconds=mttr_timeout
    )
    
    # Final verification
    recovered_cr = custom_objects_v1.get_namespaced_custom_object(
        group='pxc.percona.com',
        version='v1',
        namespace=TEST_NAMESPACE,
        plural='perconaxtradbclusters',
        name=cluster_name
    )
    final_state = recovered_cr.get('status', {}).get('state', 'unknown')
    final_pxc_ready = recovered_cr.get('status', {}).get('pxc', {}).get('ready', 0) if isinstance(recovered_cr.get('status', {}).get('pxc'), dict) else 0
    console.print(f"[green]✓ Confirmed: Cluster {cluster_name} recovered to state '{final_state}' with {final_pxc_ready} PXC nodes ready[/green]")
    assert final_state == 'ready', f"Cluster {cluster_name} did not recover to 'ready' state: {final_state}"
    assert final_pxc_ready >= TEST_EXPECTED_NODES, f"Cluster {cluster_name} did not recover PXC nodes: {final_pxc_ready}/{TEST_EXPECTED_NODES}"


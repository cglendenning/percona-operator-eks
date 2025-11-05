"""
Test that ProxySQL StatefulSet recovers after pod deletion
"""
import os
import time
import pytest
from rich.console import Console
from conftest import TEST_NAMESPACE
from tests.resiliency.helpers import (
    wait_for_statefulset_recovery,
    DEFAULT_MTTR_TIMEOUT
)

console = Console()


@pytest.mark.resiliency
def test_proxysql_statefulset_recovery(apps_v1, request):
    """Test that ProxySQL StatefulSet recovers after pod deletion"""
    console.print("[bold cyan]Starting ProxySQL StatefulSet recovery test...[/bold cyan]")
    
    console.print(f"[dim]Finding ProxySQL StatefulSet in namespace {TEST_NAMESPACE}...[/dim]")
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    proxysql_sts = [sts for sts in sts_list.items if 'proxysql' in sts.metadata.name]
    
    if not proxysql_sts:
        pytest.skip("ProxySQL StatefulSet not found")
    
    sts = proxysql_sts[0]
    sts_name = sts.metadata.name
    expected_replicas = sts.spec.replicas
    initial_ready = sts.status.ready_replicas or 0
    
    # Verify initial state
    console.print(f"[cyan]Initial state check: ProxySQL StatefulSet {sts_name}[/cyan]")
    console.print(f"  Expected replicas: {expected_replicas}")
    console.print(f"  Ready replicas: {initial_ready}")
    assert initial_ready == expected_replicas, f"Expected {expected_replicas} ready replicas, got {initial_ready}"
    console.print(f"[green]✓ Confirmed: StatefulSet {sts_name} has {initial_ready}/{expected_replicas} replicas ready[/green]")
    
    # Wait and check if replicas were reduced by chaos
    console.print(f"[cyan]Checking if StatefulSet {sts_name} was affected by chaos...[/cyan]")
    max_wait = 60
    start_time = time.time()
    sts_broken = False
    check_count = 0
    
    while time.time() - start_time < max_wait:
        check_count += 1
        elapsed = int(time.time() - start_time)
        if check_count % 5 == 0 or check_count == 1:  # Print every 5th check or first check
            console.print(f"[dim]  Check #{check_count} at {elapsed}s: Monitoring StatefulSet status...[/dim]")
        
        try:
            current_sts = apps_v1.read_namespaced_stateful_set(name=sts_name, namespace=TEST_NAMESPACE)
            current_ready = current_sts.status.ready_replicas or 0
            
            if check_count % 5 == 0 or check_count == 1:  # Print status every 5th check
                console.print(f"[dim]    Current status: {current_ready}/{expected_replicas} replicas ready[/dim]")
            
            if current_ready < expected_replicas:
                console.print(f"[yellow]⚠ StatefulSet {sts_name} is broken: {current_ready}/{expected_replicas} replicas ready[/yellow]")
                sts_broken = True
                break
        except Exception as e:
            console.print(f"[yellow]⚠ Error checking StatefulSet: {e}[/yellow]")
        
        time.sleep(3)
    
    if not sts_broken:
        console.print(f"[yellow]Note: StatefulSet {sts_name} was not affected by chaos (may have already recovered)[/yellow]")
    
    try:
        mttr_timeout = getattr(request.config.option, 'mttr_timeout', None)
        if mttr_timeout is None:
            mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    except (AttributeError, ValueError):
        mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    
    # Verify recovery
    console.print(f"[cyan]Verifying recovery: Waiting for StatefulSet {sts_name} to recover...[/cyan]")
    wait_for_statefulset_recovery(
        apps_v1,
        TEST_NAMESPACE,
        sts_name,
        expected_replicas,
        timeout_seconds=mttr_timeout
    )
    
    # Final verification
    recovered_sts = apps_v1.read_namespaced_stateful_set(name=sts_name, namespace=TEST_NAMESPACE)
    final_ready = recovered_sts.status.ready_replicas or 0
    console.print(f"[green]✓ Confirmed: StatefulSet {sts_name} recovered to {final_ready}/{expected_replicas} replicas ready[/green]")
    assert final_ready == expected_replicas, f"StatefulSet {sts_name} did not recover: {final_ready}/{expected_replicas} replicas ready"


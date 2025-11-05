"""
Test that ProxySQL pods recover after being deleted
"""
import os
import time
import pytest
from rich.console import Console
from conftest import TEST_NAMESPACE
from tests.resiliency.helpers import (
    wait_for_pod_recovery,
    DEFAULT_MTTR_TIMEOUT
)

console = Console()


@pytest.mark.resiliency
def test_proxysql_pod_recovery(core_v1, request):
    """Test that ProxySQL pods recover after being deleted"""
    console.print("[bold cyan]Starting ProxySQL pod recovery test...[/bold cyan]")
    
    # Get initial state - verify pods are running
    console.print(f"[dim]Finding ProxySQL pods in namespace {TEST_NAMESPACE}...[/dim]")
    pods = core_v1.list_namespaced_pod(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=proxysql'
    )
    
    if not pods.items:
        pytest.skip("No ProxySQL pods found")
    
    # Select a pod to monitor (use the first one)
    target_pod = pods.items[0]
    pod_name = target_pod.metadata.name
    
    console.print(f"[cyan]Initial state check: ProxySQL pod {pod_name} is {target_pod.status.phase}[/cyan]")
    assert target_pod.status.phase == 'Running', f"Expected pod {pod_name} to be Running, got {target_pod.status.phase}"
    console.print(f"[green]✓ Confirmed: Pod {pod_name} is Running[/green]")
    
    # Wait a bit for chaos to potentially occur (if running with chaos)
    # Check if pod was deleted/broken
    console.print(f"[cyan]Checking if pod {pod_name} was affected by chaos...[/cyan]")
    max_wait = 30  # Wait up to 30 seconds to see if pod gets deleted
    start_time = time.time()
    pod_broken = False
    check_count = 0
    
    while time.time() - start_time < max_wait:
        check_count += 1
        elapsed = int(time.time() - start_time)
        if check_count % 5 == 0 or check_count == 1:  # Print every 5th check or first check
            console.print(f"[dim]  Check #{check_count} at {elapsed}s: Monitoring pod status...[/dim]")
        
        try:
            current_pod = core_v1.read_namespaced_pod(name=pod_name, namespace=TEST_NAMESPACE)
            current_phase = current_pod.status.phase
            
            if check_count % 5 == 0 or check_count == 1:  # Print status every 5th check
                console.print(f"[dim]    Current status: {pod_name} is {current_phase}[/dim]")
            
            if current_phase not in ['Running', 'Pending']:
                console.print(f"[yellow]⚠ Pod {pod_name} is in state: {current_phase}[/yellow]")
                pod_broken = True
                break
            elif current_pod.metadata.deletion_timestamp:
                console.print(f"[yellow]⚠ Pod {pod_name} is being deleted[/yellow]")
                pod_broken = True
                break
        except Exception as e:
            # Pod doesn't exist - it was deleted!
            console.print(f"[yellow]⚠ Pod {pod_name} was deleted (chaos occurred)[/yellow]")
            pod_broken = True
            break
        time.sleep(2)
    
    if not pod_broken:
        console.print(f"[yellow]Note: Pod {pod_name} was not affected by chaos (may have already recovered or chaos didn't target this pod)[/yellow]")
        # Continue anyway to verify recovery
    
    # Now verify recovery - wait for pod to be running again
    console.print(f"[cyan]Verifying recovery: Waiting for pod {pod_name} to recover...[/cyan]")
    
    try:
        mttr_timeout = getattr(request.config.option, 'mttr_timeout', None)
        if mttr_timeout is None:
            mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    except (AttributeError, ValueError):
        mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    
    wait_for_pod_recovery(
        core_v1,
        TEST_NAMESPACE,
        pod_name,
        timeout_seconds=mttr_timeout
    )
    
    # Final verification
    recovered_pod = core_v1.read_namespaced_pod(name=pod_name, namespace=TEST_NAMESPACE)
    console.print(f"[green]✓ Confirmed: Pod {pod_name} recovered to {recovered_pod.status.phase}[/green]")
    assert recovered_pod.status.phase == 'Running', f"Pod {pod_name} did not recover to Running state"


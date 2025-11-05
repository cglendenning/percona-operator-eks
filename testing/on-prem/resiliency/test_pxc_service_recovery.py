"""
Test that PXC service endpoints recover after pod deletion
"""
import os
import time
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE
from tests.resiliency.helpers import (
    wait_for_service_recovery,
    DEFAULT_MTTR_TIMEOUT
)

console = Console()


@pytest.mark.resiliency
def test_pxc_service_recovery(core_v1, request):
    """Test that PXC service endpoints recover after pod deletion"""
    console.print("[bold cyan]Starting PXC service recovery test...[/bold cyan]")
    
    console.print(f"[dim]Finding PXC services in namespace {TEST_NAMESPACE}...[/dim]")
    services = core_v1.list_namespaced_service(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )
    
    if not services.items:
        pytest.skip("PXC service not found")
    
    service = services.items[0]
    service_name = service.metadata.name
    
    # Check initial endpoints
    try:
        endpoints = core_v1.read_namespaced_endpoints(name=service_name, namespace=TEST_NAMESPACE)
        initial_endpoints = sum(len(subset.addresses or []) for subset in endpoints.subsets or [])
    except Exception:
        initial_endpoints = 0
    
    # Verify initial state
    console.print(f"[cyan]Initial state check: PXC service {service_name}[/cyan]")
    console.print(f"  Initial endpoints: {initial_endpoints}")
    assert initial_endpoints > 0, f"Expected service {service_name} to have endpoints, got {initial_endpoints}"
    console.print(f"[green]✓ Confirmed: Service {service_name} has {initial_endpoints} endpoint(s)[/green]")
    
    # Wait and check if endpoints were reduced by chaos
    console.print(f"[cyan]Checking if service {service_name} was affected by chaos...[/cyan]")
    max_wait = 60
    start_time = time.time()
    service_broken = False
    check_count = 0
    
    while time.time() - start_time < max_wait:
        check_count += 1
        elapsed = int(time.time() - start_time)
        if check_count % 5 == 0 or check_count == 1:  # Print every 5th check or first check
            console.print(f"[dim]  Check #{check_count} at {elapsed}s: Monitoring service endpoints...[/dim]")
        
        try:
            current_endpoints = core_v1.read_namespaced_endpoints(name=service_name, namespace=TEST_NAMESPACE)
            current_count = sum(len(subset.addresses or []) for subset in current_endpoints.subsets or [])
            
            if check_count % 5 == 0 or check_count == 1:  # Print status every 5th check
                console.print(f"[dim]    Current status: {current_count} endpoint(s) (was {initial_endpoints})[/dim]")
            
            if current_count < initial_endpoints:
                console.print(f"[yellow]⚠ Service {service_name} is broken: {current_count} endpoints (was {initial_endpoints})[/yellow]")
                service_broken = True
                break
        except Exception as e:
            console.print(f"[yellow]⚠ Error checking endpoints: {e}[/yellow]")
        
        time.sleep(3)
    
    if not service_broken:
        console.print(f"[yellow]Note: Service {service_name} was not affected by chaos (may have already recovered)[/yellow]")
    
    try:
        mttr_timeout = getattr(request.config.option, 'mttr_timeout', None)
        if mttr_timeout is None:
            mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    except (AttributeError, ValueError):
        mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(DEFAULT_MTTR_TIMEOUT)))
    
    # Verify recovery
    console.print(f"[cyan]Verifying recovery: Waiting for service {service_name} to recover...[/cyan]")
    wait_for_service_recovery(
        core_v1,
        TEST_NAMESPACE,
        service_name,
        min_endpoints=1,
        timeout_seconds=mttr_timeout
    )
    
    # Final verification
    recovered_endpoints = core_v1.read_namespaced_endpoints(name=service_name, namespace=TEST_NAMESPACE)
    final_count = sum(len(subset.addresses or []) for subset in recovered_endpoints.subsets or [])
    console.print(f"[green]✓ Confirmed: Service {service_name} recovered to {final_count} endpoint(s)[/green]")
    assert final_count >= 1, f"Service {service_name} did not recover: {final_count} endpoints"


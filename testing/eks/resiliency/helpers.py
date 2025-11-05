"""
Helper functions for resiliency tests with polling and MTTR checks
"""
import time
import os
from typing import Callable, Optional
from rich.console import Console
from kubernetes import client

console = Console()

# Default MTTR timeout (2 minutes)
DEFAULT_MTTR_TIMEOUT = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', '120'))
# Polling interval (15 seconds)
POLL_INTERVAL = int(os.getenv('RESILIENCY_POLL_INTERVAL_SECONDS', '15'))


def poll_until_condition(
    condition_func: Callable[[], bool],
    timeout_seconds: int = DEFAULT_MTTR_TIMEOUT,
    poll_interval: int = POLL_INTERVAL,
    description: str = "condition",
    fail_message: Optional[str] = None
) -> bool:
    """
    Poll a condition function until it returns True or timeout is reached.
    
    Args:
        condition_func: Function that returns True when condition is met
        timeout_seconds: Maximum time to wait (default: from env or 120s)
        poll_interval: Seconds between polls (default: from env or 15s)
        description: Description of what we're waiting for
        fail_message: Custom failure message (default: auto-generated)
    
    Returns:
        True if condition was met, False if timeout
    
    Raises:
        AssertionError if timeout is reached
    """
    start_time = time.time()
    elapsed = 0
    poll_count = 0
    
    console.print(f"[cyan]Polling for {description}...[/cyan]")
    console.print(f"[dim]Timeout: {timeout_seconds}s, Poll interval: {poll_interval}s[/dim]")
    
    while elapsed < timeout_seconds:
        poll_count += 1
        if poll_count % 4 == 0 or poll_count == 1:  # Print every 4th poll or first poll
            console.print(f"[dim]Poll #{poll_count} at {elapsed:.0f}s: Checking {description}...[/dim]")
        
        try:
            if condition_func():
                elapsed = time.time() - start_time
                console.print(f"[green]✓ Condition met: {description} (after {elapsed:.1f}s, {poll_count} polls)[/green]")
                return True
        except Exception as e:
            console.print(f"[yellow]Poll #{poll_count} error: {e}[/yellow]")
        
        if elapsed < timeout_seconds:
            time.sleep(poll_interval)
        elapsed = time.time() - start_time
    
    # Timeout reached
    elapsed = time.time() - start_time
    error_msg = fail_message or f"Timeout waiting for {description} after {elapsed:.1f}s ({poll_count} polls)"
    console.print(f"[red]✗ {error_msg}[/red]")
    raise AssertionError(error_msg)


def check_pod_running(
    core_v1: client.CoreV1Api,
    namespace: str,
    pod_name: str
) -> bool:
    """Check if a specific pod is in Running state"""
    try:
        pod = core_v1.read_namespaced_pod(name=pod_name, namespace=namespace)
        is_running = pod.status.phase == 'Running'
        if not is_running:
            console.print(f"[yellow]Pod {pod_name} status: {pod.status.phase}[/yellow]")
        return is_running
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[yellow]Pod {pod_name} not found[/yellow]")
            return False
        raise


def check_statefulset_ready(
    apps_v1: client.AppsV1Api,
    namespace: str,
    statefulset_name: str,
    expected_replicas: int
) -> bool:
    """Check if StatefulSet has all replicas ready"""
    try:
        sts = apps_v1.read_namespaced_stateful_set(name=statefulset_name, namespace=namespace)
        ready = sts.status.ready_replicas or 0
        expected = sts.spec.replicas or expected_replicas
        is_ready = ready == expected
        
        if not is_ready:
            console.print(f"[yellow]StatefulSet {statefulset_name}: {ready}/{expected} ready[/yellow]")
        return is_ready
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[yellow]StatefulSet {statefulset_name} not found[/yellow]")
            return False
        raise


def check_service_endpoints(
    core_v1: client.CoreV1Api,
    namespace: str,
    service_name: str,
    min_endpoints: int = 1
) -> bool:
    """Check if service has minimum number of endpoints"""
    try:
        endpoints = core_v1.read_namespaced_endpoints(name=service_name, namespace=namespace)
        addresses = []
        for subset in endpoints.subsets or []:
            addresses.extend([addr.ip for addr in subset.addresses or []])
        
        has_endpoints = len(addresses) >= min_endpoints
        if not has_endpoints:
            console.print(f"[yellow]Service {service_name}: {len(addresses)} endpoints (need {min_endpoints})[/yellow]")
        return has_endpoints
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[yellow]Service {service_name} not found[/yellow]")
            return False
        raise


def check_cluster_status_ready(
    custom_objects_v1: client.CustomObjectsApi,
    namespace: str,
    cluster_name: str,
    expected_nodes: int
) -> bool:
    """Check if Percona cluster status is ready"""
    try:
        cr = custom_objects_v1.get_namespaced_custom_object(
            group='pxc.percona.com',
            version='v1',
            namespace=namespace,
            plural='perconaxtradbclusters',
            name=cluster_name
        )
        
        status = cr.get('status', {})
        state = status.get('state', 'unknown')
        
        if state != 'ready':
            console.print(f"[yellow]Cluster {cluster_name} state: {state} (expected: ready)[/yellow]")
            return False
        
        # Check PXC ready count
        pxc_status = status.get('pxc', {})
        if isinstance(pxc_status, dict):
            pxc_ready = pxc_status.get('ready', 0)
        else:
            pxc_ready = pxc_status
        
        if pxc_ready < expected_nodes:
            console.print(f"[yellow]Cluster {cluster_name}: {pxc_ready}/{expected_nodes} PXC nodes ready[/yellow]")
            return False
        
        return True
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[yellow]Cluster {cluster_name} not found[/yellow]")
            return False
        raise


def check_pvc_bound(
    core_v1: client.CoreV1Api,
    namespace: str,
    pvc_name: str
) -> bool:
    """Check if PVC is in Bound state"""
    try:
        pvc = core_v1.read_namespaced_persistent_volume_claim(name=pvc_name, namespace=namespace)
        is_bound = pvc.status.phase == 'Bound'
        if not is_bound:
            console.print(f"[yellow]PVC {pvc_name} status: {pvc.status.phase}[/yellow]")
        return is_bound
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[yellow]PVC {pvc_name} not found[/yellow]")
            return False
        raise


def wait_for_pod_recovery(
    core_v1: client.CoreV1Api,
    namespace: str,
    pod_name: str,
    timeout_seconds: int = DEFAULT_MTTR_TIMEOUT
) -> None:
    """Wait for a pod to be running after chaos event"""
    poll_until_condition(
        condition_func=lambda: check_pod_running(core_v1, namespace, pod_name),
        timeout_seconds=timeout_seconds,
        description=f"pod {pod_name} to be Running",
        fail_message=f"Pod {pod_name} did not recover to Running state within {timeout_seconds}s"
    )


def wait_for_statefulset_recovery(
    apps_v1: client.AppsV1Api,
    namespace: str,
    statefulset_name: str,
    expected_replicas: int,
    timeout_seconds: int = DEFAULT_MTTR_TIMEOUT
) -> None:
    """Wait for StatefulSet to have all replicas ready after chaos event"""
    poll_until_condition(
        condition_func=lambda: check_statefulset_ready(apps_v1, namespace, statefulset_name, expected_replicas),
        timeout_seconds=timeout_seconds,
        description=f"StatefulSet {statefulset_name} to have {expected_replicas} ready replicas",
        fail_message=f"StatefulSet {statefulset_name} did not recover to {expected_replicas} ready replicas within {timeout_seconds}s"
    )


def wait_for_service_recovery(
    core_v1: client.CoreV1Api,
    namespace: str,
    service_name: str,
    min_endpoints: int = 1,
    timeout_seconds: int = DEFAULT_MTTR_TIMEOUT
) -> None:
    """Wait for service to have endpoints after chaos event"""
    poll_until_condition(
        condition_func=lambda: check_service_endpoints(core_v1, namespace, service_name, min_endpoints),
        timeout_seconds=timeout_seconds,
        description=f"service {service_name} to have at least {min_endpoints} endpoint(s)",
        fail_message=f"Service {service_name} did not recover endpoints within {timeout_seconds}s"
    )


def wait_for_cluster_recovery(
    custom_objects_v1: client.CustomObjectsApi,
    namespace: str,
    cluster_name: str,
    expected_nodes: int,
    timeout_seconds: int = DEFAULT_MTTR_TIMEOUT
) -> None:
    """Wait for Percona cluster to be ready after chaos event"""
    poll_until_condition(
        condition_func=lambda: check_cluster_status_ready(custom_objects_v1, namespace, cluster_name, expected_nodes),
        timeout_seconds=timeout_seconds,
        description=f"cluster {cluster_name} to be ready",
        fail_message=f"Cluster {cluster_name} did not recover to ready state within {timeout_seconds}s"
    )


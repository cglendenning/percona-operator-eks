"""
LitmusChaos integration for triggering resiliency tests after chaos events
"""
import os
import time
import subprocess
import json
from typing import Dict, Optional, Any
from rich.console import Console
from kubernetes import client, config

console = Console()

# Configuration from environment
CHAOS_NAMESPACE = os.getenv('CHAOS_NAMESPACE', 'litmus')
TEST_NAMESPACE = os.getenv('TEST_NAMESPACE', 'percona')
MTTR_TIMEOUT = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', '120'))


def load_k8s_config():
    """Load Kubernetes configuration"""
    try:
        config.load_incluster_config()
        console.print("[dim]Using in-cluster Kubernetes config[/dim]")
    except config.ConfigException:
        try:
            config.load_kube_config()
            console.print("[dim]Using local Kubernetes config[/dim]")
        except Exception as e:
            console.print(f"[red]Failed to load Kubernetes config: {e}[/red]")
            raise


def get_chaos_engine_result(chaos_namespace: str, engine_name: str) -> Optional[Dict[str, Any]]:
    """Get the ChaosEngine result after experiment completes"""
    try:
        custom_objects_v1 = client.CustomObjectsApi()
        
        # Get ChaosEngine
        engine = custom_objects_v1.get_namespaced_custom_object(
            group='litmuschaos.io',
            version='v1alpha1',
            namespace=chaos_namespace,
            plural='chaosengines',
            name=engine_name
        )
        
        # Get ChaosResult
        result_name = engine.get('metadata', {}).get('name', engine_name) + '-result'
        result = custom_objects_v1.get_namespaced_custom_object(
            group='litmuschaos.io',
            version='v1alpha1',
            namespace=chaos_namespace,
            plural='chaosresults',
            name=result_name
        )
        
        return result
    except client.exceptions.ApiException as e:
        console.print(f"[yellow]Could not get chaos result: {e}[/yellow]")
        return None


def wait_for_chaos_completion(chaos_namespace: str, engine_name: str, timeout: int = 300) -> bool:
    """
    Wait for a chaos experiment to complete.
    
    Returns:
        True if chaos completed successfully, False otherwise
    """
    start_time = time.time()
    console.print(f"[cyan]Waiting for chaos experiment {engine_name} to complete...[/cyan]")
    
    while time.time() - start_time < timeout:
        result = get_chaos_engine_result(chaos_namespace, engine_name)
        
        if result:
            verdict = result.get('status', {}).get('experimentStatus', {}).get('verdict', '')
            
            if verdict in ['Pass', 'Fail']:
                console.print(f"[green]Chaos experiment completed with verdict: {verdict}[/green]")
                return verdict == 'Pass'
            else:
                console.print(f"[dim]Chaos experiment status: {verdict}[/dim]")
        
        time.sleep(5)
    
    console.print(f"[red]Timeout waiting for chaos experiment to complete[/red]")
    return False


def trigger_resiliency_test(test_type: str, test_params: Dict[str, Any], mttr_timeout: int = MTTR_TIMEOUT):
    """
    Trigger a resiliency test after chaos event.
    
    Args:
        test_type: Type of resiliency test (e.g., 'pod_recovery', 'statefulset_recovery')
        test_params: Parameters for the test
        mttr_timeout: MTTR timeout in seconds
    """
    console.print(f"[cyan]Triggering resiliency test: {test_type}[/cyan]")
    console.print(f"[dim]MTTR timeout: {mttr_timeout}s[/dim]")
    
    # Import here to avoid circular dependencies
    from tests.resiliency.helpers import (
        wait_for_pod_recovery,
        wait_for_statefulset_recovery,
        wait_for_service_recovery,
        wait_for_cluster_recovery
    )
    
    load_k8s_config()
    core_v1 = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    custom_objects_v1 = client.CustomObjectsApi()
    
    try:
        if test_type == 'pod_recovery':
            wait_for_pod_recovery(
                core_v1,
                test_params['namespace'],
                test_params['pod_name'],
                timeout_seconds=mttr_timeout
            )
        elif test_type == 'statefulset_recovery':
            wait_for_statefulset_recovery(
                apps_v1,
                test_params['namespace'],
                test_params['statefulset_name'],
                test_params['expected_replicas'],
                timeout_seconds=mttr_timeout
            )
        elif test_type == 'service_recovery':
            wait_for_service_recovery(
                core_v1,
                test_params['namespace'],
                test_params['service_name'],
                test_params.get('min_endpoints', 1),
                timeout_seconds=mttr_timeout
            )
        elif test_type == 'cluster_recovery':
            wait_for_cluster_recovery(
                custom_objects_v1,
                test_params['namespace'],
                test_params['cluster_name'],
                test_params['expected_nodes'],
                timeout_seconds=mttr_timeout
            )
        else:
            raise ValueError(f"Unknown resiliency test type: {test_type}")
        
        console.print(f"[green]✓ Resiliency test passed: {test_type}[/green]")
        return True
    except AssertionError as e:
        console.print(f"[red]✗ Resiliency test failed: {test_type} - {e}[/red]")
        return False
    except Exception as e:
        console.print(f"[red]✗ Resiliency test error: {test_type} - {e}[/red]")
        return False


def run_resiliency_test_from_chaos_event(engine_name: str, chaos_namespace: str = CHAOS_NAMESPACE):
    """
    Main entry point: Wait for chaos event to complete, then trigger appropriate resiliency test.
    
    This is called automatically by LitmusChaos after chaos experiments complete.
    """
    console.print(f"[bold cyan]Resiliency Test Triggered by Chaos Event[/bold cyan]")
    console.print(f"Chaos Engine: {engine_name}")
    console.print(f"Namespace: {chaos_namespace}")
    
    # Wait for chaos to complete
    if not wait_for_chaos_completion(chaos_namespace, engine_name):
        console.print("[yellow]Chaos experiment did not complete successfully, skipping resiliency test[/yellow]")
        return False
    
    # Determine test type and parameters from chaos engine
    # This is a simplified version - in practice, you'd parse the ChaosEngine spec
    # to determine what was affected (pod, statefulset, service, etc.)
    
    # For now, we'll use environment variables or default behavior
    # In production, this would be more sophisticated
    
    test_type = os.getenv('RESILIENCY_TEST_TYPE', 'cluster_recovery')
    
    test_params = {
        'namespace': TEST_NAMESPACE,
        'cluster_name': os.getenv('TEST_CLUSTER_NAME', 'pxc-cluster-pxc-db'),
        'expected_nodes': int(os.getenv('TEST_EXPECTED_NODES', '3')),
    }
    
    # Override with specific params if provided
    if os.getenv('RESILIENCY_POD_NAME'):
        test_type = 'pod_recovery'
        test_params['pod_name'] = os.getenv('RESILIENCY_POD_NAME')
    
    if os.getenv('RESILIENCY_STATEFULSET_NAME'):
        test_type = 'statefulset_recovery'
        test_params['statefulset_name'] = os.getenv('RESILIENCY_STATEFULSET_NAME')
        test_params['expected_replicas'] = int(os.getenv('RESILIENCY_EXPECTED_REPLICAS', '3'))
    
    if os.getenv('RESILIENCY_SERVICE_NAME'):
        test_type = 'service_recovery'
        test_params['service_name'] = os.getenv('RESILIENCY_SERVICE_NAME')
    
    mttr_timeout = int(os.getenv('RESILIENCY_MTTR_TIMEOUT_SECONDS', str(MTTR_TIMEOUT)))
    
    return trigger_resiliency_test(test_type, test_params, mttr_timeout)


if __name__ == '__main__':
    import sys
    engine_name = sys.argv[1] if len(sys.argv) > 1 else os.getenv('CHAOS_ENGINE_NAME', '')
    if not engine_name:
        console.print("[red]Error: Chaos engine name required[/red]")
        sys.exit(1)
    
    success = run_resiliency_test_from_chaos_event(engine_name)
    sys.exit(0 if success else 1)


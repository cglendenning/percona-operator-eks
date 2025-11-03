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
        
        # Get experiment name from the engine
        experiments = engine.get('spec', {}).get('experiments', [])
        if experiments:
            exp_name = experiments[0].get('name', 'pod-delete')
            # ChaosResult naming pattern is: {engine_name}-{experiment_name}
            result_name = f"{engine_name}-{exp_name}"
        else:
            # Fallback to old pattern
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
        # 404 is expected while experiment is initializing - don't spam logs
        if e.status != 404:
            console.print(f"[yellow]Could not get chaos result: {e}[/yellow]")
        return None


def wait_for_chaos_completion(chaos_namespace: str, engine_name: str, timeout: int = 180) -> bool:
    """
    Wait for a chaos experiment to complete.
    
    Args:
        chaos_namespace: Namespace where chaos resources are
        engine_name: Name of the ChaosEngine
        timeout: Maximum time to wait in seconds (default: 180s - 3 minutes)
    
    Returns:
        True if chaos completed successfully, False otherwise
    """
    start_time = time.time()
    elapsed = 0
    check_count = 0
    not_started_start = None  # Track when we first see "not-started"
    max_not_started_time = 60  # Fail if stuck in not-started for 60 seconds
    
    console.print(f"[cyan]Waiting for chaos experiment {engine_name} to complete...[/cyan]")
    console.print(f"[dim]Timeout: {timeout}s, checking every 5 seconds...[/dim]")
    
    # Quick check: Is chaos operator running?
    try:
        core_v1 = client.CoreV1Api()
        operator_pods = core_v1.list_namespaced_pod(
            namespace=chaos_namespace,
            label_selector='app.kubernetes.io/name=litmus'
        )
        running_operators = [p for p in operator_pods.items if p.status.phase == 'Running']
        if not running_operators:
            console.print(f"[red]✗ Chaos operator not running in namespace {chaos_namespace}[/red]")
            console.print(f"[yellow]ChaosEngine may never start without the operator[/yellow]")
        else:
            console.print(f"[dim]✓ Chaos operator running: {len(running_operators)} pod(s)[/dim]")
    except Exception as e:
        console.print(f"[yellow]Could not verify chaos operator status: {e}[/yellow]")
    
    engine = None
    while elapsed < timeout:
        check_count += 1
        elapsed = int(time.time() - start_time)
        
        # Always check engine status (not just when printing)
        try:
            custom_objects_v1 = client.CustomObjectsApi()
            engine = custom_objects_v1.get_namespaced_custom_object(
                group='litmuschaos.io',
                version='v1alpha1',
                namespace=chaos_namespace,
                plural='chaosengines',
                name=engine_name
            )
            engine_status = engine.get('status', {}).get('engineStatus', 'not-started')
            experiments = engine.get('status', {}).get('experiments', [])
            
            # Track if stuck in "not-started" for too long (check every iteration)
            if engine_status == 'not-started':
                if not_started_start is None:
                    not_started_start = elapsed
                else:
                    stuck_time = elapsed - not_started_start
                    if stuck_time >= max_not_started_time:
                        console.print(f"[red]✗ ChaosEngine stuck in 'not-started' for {stuck_time}s (max: {max_not_started_time}s)[/red]")
                        console.print(f"[yellow]This usually means the chaos operator isn't processing the ChaosEngine[/yellow]")
                        console.print(f"[yellow]Check operator logs: kubectl logs -n {chaos_namespace} -l app.kubernetes.io/name=litmus[/yellow]")
                        return False
            else:
                # Status changed, reset the timer
                not_started_start = None
        except Exception as e:
            # If we can't get engine status, continue (might be transient API issue)
            if check_count == 1:
                console.print(f"[yellow]Could not get ChaosEngine status: {e}[/yellow]")
        
        # Print progress every 30 seconds or on first check
        if check_count % 6 == 0 or check_count == 1:
            console.print(f"[dim]  Check #{check_count} at {elapsed}s: Checking chaos experiment status...[/dim]")
            
            # Get detailed status information for display
            if engine:
                try:
                    core_v1 = client.CoreV1Api()
                    batch_v1 = client.BatchV1Api()
                    
                    engine_status = engine.get('status', {}).get('engineStatus', 'not-started')
                    experiments = engine.get('status', {}).get('experiments', [])
                    
                    console.print(f"[dim]    → ChaosEngine status: {engine_status}[/dim]")
                    
                    if experiments:
                        for exp in experiments:
                            exp_name = exp.get('name', 'unknown')
                            exp_status = exp.get('status', 'unknown')
                            exp_verdict = exp.get('verdict', 'Awaited')
                            runner_pod = exp.get('runner', 'none')
                            console.print(f"[dim]    → Experiment '{exp_name}': status={exp_status}, verdict={exp_verdict}[/dim]")
                            if runner_pod and runner_pod != 'none':
                                console.print(f"[dim]    → Runner pod: {runner_pod}[/dim]")
                except Exception:
                    console.print(f"[dim]    → ChaosEngine: Unable to get status[/dim]")
                
                # Check for runner pods
                try:
                    pods = core_v1.list_namespaced_pod(
                        namespace=chaos_namespace,
                        label_selector=f'chaosUID={engine.get("metadata", {}).get("uid", "")}'
                    )
                    if pods.items:
                        for pod in pods.items:
                            pod_status = pod.status.phase
                            console.print(f"[dim]    → Runner pod {pod.metadata.name}: {pod_status}[/dim]")
                except Exception:
                    pass
                
                # Check for experiment jobs
                try:
                    jobs = batch_v1.list_namespaced_job(
                        namespace=chaos_namespace,
                        label_selector=f'name={engine_name}'
                    )
                    if jobs.items:
                        for job in jobs.items:
                            succeeded = job.status.succeeded or 0
                            failed = job.status.failed or 0
                            active = job.status.active or 0
                            console.print(f"[dim]    → Job {job.metadata.name}: active={active}, succeeded={succeeded}, failed={failed}[/dim]")
                            
                            # Get job pod logs to see what's happening
                            try:
                                job_pods = core_v1.list_namespaced_pod(
                                    namespace=chaos_namespace,
                                    label_selector=f'job-name={job.metadata.name}'
                                )
                                for pod in job_pods.items:
                                    if pod.status.phase == 'Running' or pod.status.phase == 'Succeeded':
                                        # Get last few log lines
                                        try:
                                            logs = core_v1.read_namespaced_pod_log(
                                                name=pod.metadata.name,
                                                namespace=chaos_namespace,
                                                tail_lines=3,
                                                timestamps=False
                                            )
                                            if logs:
                                                log_lines = logs.strip().split('\n')
                                                console.print(f"[dim]      Job pod logs (last 3 lines):[/dim]")
                                                for line in log_lines:
                                                    console.print(f"[dim]        {line}[/dim]")
                                        except Exception:
                                            pass
                            except Exception:
                                pass
                    else:
                        console.print(f"[dim]    → No experiment jobs found yet[/dim]")
                except Exception:
                    pass
                    
            except Exception:
                pass
        
        # Check if experiment is complete based on ChaosEngine status (not just ChaosResult)
        if engine:
            experiments = engine.get('status', {}).get('experiments', [])
            if experiments:
                for exp in experiments:
                    exp_status = exp.get('status', '')
                    exp_verdict = exp.get('verdict', '')
                    
                    # If experiment is completed, we can exit
                    if exp_status == 'Completed' and exp_verdict in ['Pass', 'Fail']:
                        console.print(f"[green]✓ Chaos experiment completed with verdict: {exp_verdict} (after {elapsed}s)[/green]")
                        console.print(f"[dim]  Experiment status from ChaosEngine: {exp_status}[/dim]")
                        return exp_verdict == 'Pass'
        
        # Also check ChaosResult (for compatibility)
        result = get_chaos_engine_result(chaos_namespace, engine_name)
        
        if result:
            verdict = result.get('status', {}).get('experimentStatus', {}).get('verdict', '')
            phase = result.get('status', {}).get('experimentStatus', {}).get('phase', 'unknown')
            
            if check_count % 6 == 0 or check_count == 1:
                console.print(f"[dim]    → ChaosResult: phase={phase}, verdict={verdict}[/dim]")
            
            if verdict in ['Pass', 'Fail']:
                console.print(f"[green]✓ Chaos experiment completed with verdict: {verdict} (after {elapsed}s)[/green]")
                return verdict == 'Pass'
        else:
            if check_count % 6 == 0:
                console.print(f"[dim]    → ChaosResult: Not yet created (waiting for experiment to start)[/dim]")
                
                # Show additional diagnostics when result isn't ready
                try:
                    # Check target application pods
                    target_app_ns = engine.get('spec', {}).get('appinfo', {}).get('appns', 'unknown')
                    target_app_label = engine.get('spec', {}).get('appinfo', {}).get('applabel', '')
                    
                    if target_app_label and target_app_ns != 'unknown':
                        console.print(f"[dim]    → Target app: namespace={target_app_ns}, label={target_app_label}[/dim]")
                        try:
                            target_pods = core_v1.list_namespaced_pod(
                                namespace=target_app_ns,
                                label_selector=target_app_label
                            )
                            running_count = sum(1 for p in target_pods.items if p.status.phase == 'Running')
                            total_count = len(target_pods.items)
                            console.print(f"[dim]    → Target pods: {running_count}/{total_count} running[/dim]")
                            
                            # Show any pods not in Running state
                            for pod in target_pods.items:
                                if pod.status.phase != 'Running':
                                    console.print(f"[dim]      • {pod.metadata.name}: {pod.status.phase}[/dim]")
                        except Exception:
                            pass
                    
                    # Check for recent events in chaos namespace
                    try:
                        events = core_v1.list_namespaced_event(
                            namespace=chaos_namespace,
                            field_selector=f'involvedObject.name={engine_name}'
                        )
                        if events.items:
                            # Get most recent event
                            sorted_events = sorted(events.items, key=lambda e: e.last_timestamp or e.event_time, reverse=True)
                            recent_event = sorted_events[0]
                            console.print(f"[dim]    → Recent event: {recent_event.reason} - {recent_event.message}[/dim]")
                    except Exception:
                        pass
                        
                except Exception:
                    pass
        
        time.sleep(5)
        elapsed = time.time() - start_time
    
    console.print(f"[red]✗ Timeout waiting for chaos experiment to complete after {elapsed:.0f}s[/red]")
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


def trigger_chaos_experiment(
    experiment_type: str = 'pod-delete',
    app_namespace: str = TEST_NAMESPACE,
    app_label: str = 'app.kubernetes.io/component=pxc',
    app_kind: str = 'statefulset',
    chaos_namespace: str = CHAOS_NAMESPACE,
    total_chaos_duration: int = 60,
    chaos_interval: int = 10
) -> Optional[str]:
    """
    Trigger a LitmusChaos experiment and return the ChaosEngine name.
    
    Args:
        experiment_type: Type of chaos experiment (e.g., 'pod-delete')
        app_namespace: Namespace of the application to target
        app_label: Label selector for the application
        app_kind: Kind of Kubernetes resource (statefulset, deployment, etc.)
        chaos_namespace: Namespace where LitmusChaos is installed
        total_chaos_duration: Total duration of chaos in seconds
        chaos_interval: Interval between chaos events in seconds
    
    Returns:
        ChaosEngine name if successful, None otherwise
    """
    load_k8s_config()
    custom_objects_v1 = client.CustomObjectsApi()
    apiextensions_v1 = client.ApiextensionsV1Api()
    core_v1 = client.CoreV1Api()
    
    # First, check if LitmusChaos is installed by verifying CRD exists
    console.print(f"[dim]Checking if LitmusChaos CRDs are installed...[/dim]")
    try:
        crd = apiextensions_v1.read_custom_resource_definition(name='chaosengines.litmuschaos.io')
        console.print(f"[green]✓ LitmusChaos CRD 'chaosengines.litmuschaos.io' found[/green]")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[red]✗ LitmusChaos CRDs not found (404)[/red]")
            console.print(f"[yellow]LitmusChaos is not installed or CRDs are missing.[/yellow]")
            console.print(f"[yellow]Please install LitmusChaos first:[/yellow]")
            console.print(f"[cyan]  ./install-litmus.sh[/cyan]")
            console.print(f"[cyan]  OR[/cyan]")
            console.print(f"[cyan]  npm run percona -- install[/cyan]")
            return None
        else:
            console.print(f"[red]✗ Error checking for LitmusChaos CRD: {e}[/red]")
            return None
    
    # Check if namespace exists
    try:
        core_v1.read_namespace(name=chaos_namespace)
        console.print(f"[green]✓ LitmusChaos namespace '{chaos_namespace}' exists[/green]")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            console.print(f"[red]✗ LitmusChaos namespace '{chaos_namespace}' not found[/red]")
            console.print(f"[yellow]Please install LitmusChaos first: ./install-litmus.sh[/yellow]")
            return None
        else:
            console.print(f"[red]✗ Error checking namespace: {e}[/red]")
            return None
    
    # Generate unique engine name
    import uuid
    engine_name = f"resiliency-test-{experiment_type}-{uuid.uuid4().hex[:8]}"
    
    console.print(f"[bold cyan]Triggering chaos experiment: {experiment_type}[/bold cyan]")
    console.print(f"  Target: {app_kind} with label {app_label} in {app_namespace}")
    console.print(f"  Engine name: {engine_name}")
    
    # Create ChaosEngine manifest
    chaos_engine = {
        'apiVersion': 'litmuschaos.io/v1alpha1',
        'kind': 'ChaosEngine',
        'metadata': {
            'name': engine_name,
            'namespace': chaos_namespace,
            'labels': {
                'chaos-type': experiment_type,
                'resiliency-test': 'true'
            }
        },
        'spec': {
            'appinfo': {
                'appns': app_namespace,
                'applabel': app_label,
                'appkind': app_kind
            },
            'chaosServiceAccount': 'litmus-admin',
            'monitoring': False,
            'jobCleanUpPolicy': 'retain',
            'experiments': [
                {
                    'name': experiment_type,
                    'spec': {
                        'components': {
                            'env': [
                                {
                                    'name': 'TOTAL_CHAOS_DURATION',
                                    'value': str(total_chaos_duration)
                                },
                                {
                                    'name': 'CHAOS_INTERVAL',
                                    'value': str(chaos_interval)
                                },
                                {
                                    'name': 'FORCE',
                                    'value': 'false'
                                },
                                {
                                    'name': 'RANDOMNESS',
                                    'value': 'true'
                                }
                            ]
                        }
                    }
                }
            ]
        }
    }
    
    try:
        # Create the ChaosEngine
        custom_objects_v1.create_namespaced_custom_object(
            group='litmuschaos.io',
            version='v1alpha1',
            namespace=chaos_namespace,
            plural='chaosengines',
            body=chaos_engine
        )
        console.print(f"[green]✓ ChaosEngine created: {engine_name}[/green]")
        return engine_name
    except Exception as e:
        console.print(f"[red]✗ Failed to create ChaosEngine: {e}[/red]")
        return None


def run_resiliency_tests_with_chaos(
    experiment_type: str = 'pod-delete',
    app_namespace: str = TEST_NAMESPACE,
    app_label: str = 'app.kubernetes.io/component=pxc',
    app_kind: str = 'statefulset',
    mttr_timeout: int = MTTR_TIMEOUT
) -> bool:
    """
    Trigger chaos experiment and run resiliency tests.
    
    This function:
    1. Triggers a chaos experiment
    2. Waits for chaos to complete
    3. Runs appropriate resiliency tests
    4. Returns True if all tests pass
    """
    chaos_namespace = CHAOS_NAMESPACE
    
    # Check if LitmusChaos is installed
    try:
        load_k8s_config()
        core_v1 = client.CoreV1Api()
        core_v1.read_namespace(name=chaos_namespace)
    except Exception as e:
        console.print(f"[red]✗ LitmusChaos not found in namespace '{chaos_namespace}'[/red]")
        console.print(f"[yellow]Please install LitmusChaos first: ./install-litmus.sh[/yellow]")
        return False
    
    # Trigger chaos
    engine_name = trigger_chaos_experiment(
        experiment_type=experiment_type,
        app_namespace=app_namespace,
        app_label=app_label,
        app_kind=app_kind,
        chaos_namespace=chaos_namespace
    )
    
    if not engine_name:
        return False
    
    # Wait for chaos to complete
    if not wait_for_chaos_completion(chaos_namespace, engine_name, timeout=180):
        console.print("[red]✗ Chaos experiment did not complete successfully[/red]")
        return False
    
    # Determine test type based on experiment and app kind
    test_type = 'cluster_recovery'  # default
    
    # Get test parameters from cluster state
    apps_v1 = client.AppsV1Api()
    custom_objects_v1 = client.CustomObjectsApi()
    
    test_params = {
        'namespace': app_namespace,
        'expected_nodes': int(os.getenv('TEST_EXPECTED_NODES', '3')),
    }
    
    if app_kind.lower() == 'statefulset':
        try:
            sts_list = apps_v1.list_namespaced_stateful_set(namespace=app_namespace, label_selector=app_label)
            if sts_list.items:
                sts = sts_list.items[0]
                test_type = 'statefulset_recovery'
                test_params['statefulset_name'] = sts.metadata.name
                test_params['expected_replicas'] = sts.spec.replicas
        except Exception as e:
            console.print(f"[yellow]Could not get StatefulSet info: {e}[/yellow]")
    elif 'service' in app_label.lower() or app_kind.lower() == 'service':
        try:
            services = core_v1.list_namespaced_service(namespace=app_namespace, label_selector=app_label)
            if services.items:
                test_type = 'service_recovery'
                test_params['service_name'] = services.items[0].metadata.name
                test_params['min_endpoints'] = 1
        except Exception as e:
            console.print(f"[yellow]Could not get Service info: {e}[/yellow]")
    
    # Get cluster name for cluster recovery test
    if test_type == 'cluster_recovery':
        test_params['cluster_name'] = os.getenv('TEST_CLUSTER_NAME', f'{os.getenv("TEST_CLUSTER_NAME", "pxc-cluster")}-pxc-db')
    
    # Run resiliency test
    console.print(f"[bold cyan]Running resiliency test: {test_type}[/bold cyan]")
    success = trigger_resiliency_test(test_type, test_params, mttr_timeout)
    
    # Cleanup chaos engine
    try:
        custom_objects_v1 = client.CustomObjectsApi()
        custom_objects_v1.delete_namespaced_custom_object(
            group='litmuschaos.io',
            version='v1alpha1',
            namespace=chaos_namespace,
            plural='chaosengines',
            name=engine_name
        )
        console.print(f"[dim]Cleaned up ChaosEngine: {engine_name}[/dim]")
    except Exception as e:
        console.print(f"[yellow]Could not cleanup ChaosEngine: {e}[/yellow]")
    
    return success


if __name__ == '__main__':
    import sys
    engine_name = sys.argv[1] if len(sys.argv) > 1 else os.getenv('CHAOS_ENGINE_NAME', '')
    if not engine_name:
        console.print("[red]Error: Chaos engine name required[/red]")
        sys.exit(1)
    
    success = run_resiliency_test_from_chaos_event(engine_name)
    sys.exit(0 if success else 1)


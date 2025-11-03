"""
Data-driven disaster recovery scenario tests
"""
import json
import os
import pytest
from kubernetes import client
from tests.resiliency.chaos_integration import trigger_chaos_experiment, wait_for_chaos_completion
from tests.resiliency.helpers import (
    wait_for_pod_recovery,
    wait_for_statefulset_recovery,
    wait_for_cluster_recovery,
    wait_for_service_recovery
)
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

# Path to DR scenarios JSON file
SCENARIOS_FILE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(__file__))),
    'disaster_scenarios',
    'disaster_scenarios.json'
)


def load_dr_scenarios():
    """
    Load disaster recovery scenarios from JSON file.
    Returns only scenarios that are marked as test_enabled=true.
    """
    with open(SCENARIOS_FILE, 'r') as f:
        all_scenarios = json.load(f)
    
    # Filter to only enabled scenarios
    enabled_scenarios = [s for s in all_scenarios if s.get('test_enabled', False)]
    
    return enabled_scenarios


@pytest.mark.dr
@pytest.mark.parametrize('scenario', load_dr_scenarios(), ids=lambda s: s.get('scenario', 'unknown'))
def test_dr_scenario_recovery(scenario, core_v1, apps_v1, custom_objects_v1):
    """
    Test disaster recovery for a specific scenario by:
    1. Triggering chaos based on scenario parameters
    2. Waiting for chaos to complete
    3. Verifying recovery based on expected_recovery type
    """
    print(f"\n{'='*80}")
    print(f"DR Scenario: {scenario['scenario']}")
    print(f"Description: {scenario.get('test_description', 'N/A')}")
    print(f"Business Impact: {scenario.get('business_impact', 'N/A')}")
    print(f"RTO Target: {scenario.get('rto_target', 'N/A')}")
    print(f"RPO Target: {scenario.get('rpo_target', 'N/A')}")
    print(f"{'='*80}\n")
    
    # Extract chaos parameters
    chaos_type = scenario.get('chaos_type')
    target_label = scenario.get('target_label')
    app_kind = scenario.get('app_kind')
    total_chaos_duration = scenario.get('total_chaos_duration', 60)
    chaos_interval = scenario.get('chaos_interval', 10)
    
    # Extract recovery parameters
    expected_recovery = scenario.get('expected_recovery')
    mttr_seconds = scenario.get('mttr_seconds', 600)
    poll_interval = scenario.get('poll_interval', 15)
    
    # Validate required fields
    assert chaos_type, f"Scenario '{scenario['scenario']}' missing 'chaos_type'"
    assert target_label, f"Scenario '{scenario['scenario']}' missing 'target_label'"
    assert app_kind, f"Scenario '{scenario['scenario']}' missing 'app_kind'"
    assert expected_recovery, f"Scenario '{scenario['scenario']}' missing 'expected_recovery'"
    
    # Step 1: Trigger chaos experiment
    print(f"[1/3] Triggering chaos: {chaos_type}")
    print(f"      Target: {app_kind} with label '{target_label}'")
    print(f"      Duration: {total_chaos_duration}s, Interval: {chaos_interval}s\n")
    
    engine_name = trigger_chaos_experiment(
        experiment_type=chaos_type,
        app_namespace=TEST_NAMESPACE,
        app_label=target_label,
        app_kind=app_kind,
        total_chaos_duration=total_chaos_duration,
        chaos_interval=chaos_interval
    )
    
    assert engine_name is not None, f"Failed to trigger chaos experiment for scenario: {scenario['scenario']}"
    print(f"✓ Chaos engine created: {engine_name}\n")
    
    # Step 2: Wait for chaos to complete
    print(f"[2/3] Waiting for chaos experiment to complete...")
    wait_for_chaos_completion(
        chaos_namespace='litmus',
        engine_name=engine_name,
        timeout=max(600, total_chaos_duration + 300)  # Add buffer beyond chaos duration
    )
    print(f"✓ Chaos experiment completed\n")
    
    # Step 3: Verify recovery based on expected_recovery type
    print(f"[3/3] Verifying recovery: {expected_recovery}")
    print(f"      Timeout: {mttr_seconds}s, Poll interval: {poll_interval}s\n")
    
    if expected_recovery == 'cluster_ready':
        # Verify the Percona cluster is ready
        wait_for_cluster_recovery(
            custom_objects_v1=custom_objects_v1,
            namespace=TEST_NAMESPACE,
            cluster_name=TEST_CLUSTER_NAME,
            expected_nodes=3,  # PXC nodes (not including ProxySQL)
            timeout_seconds=mttr_seconds
        )
        print(f"✓ Cluster {TEST_CLUSTER_NAME} recovered to ready state\n")
        
    elif expected_recovery == 'statefulset_ready':
        # Get StatefulSet name from target label
        # Parse label like "app.kubernetes.io/component=pxc" to find StatefulSet
        label_selector = target_label
        apps_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector=label_selector
        )
        
        assert apps_list.items, f"No StatefulSets found with label '{label_selector}'"
        sts_name = apps_list.items[0].metadata.name
        expected_replicas = apps_list.items[0].spec.replicas
        
        wait_for_statefulset_recovery(
            apps_v1=apps_v1,
            namespace=TEST_NAMESPACE,
            statefulset_name=sts_name,
            expected_replicas=expected_replicas,
            timeout_seconds=mttr_seconds
        )
        print(f"✓ StatefulSet {sts_name} recovered to {expected_replicas} replicas\n")
        
    elif expected_recovery == 'pods_running':
        # Get a pod from the target label and verify it's running
        label_selector = target_label
        pods_list = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector=label_selector
        )
        
        assert pods_list.items, f"No pods found with label '{label_selector}'"
        pod_name = pods_list.items[0].metadata.name
        
        wait_for_pod_recovery(
            core_v1=core_v1,
            namespace=TEST_NAMESPACE,
            pod_name=pod_name,
            timeout_seconds=mttr_seconds
        )
        print(f"✓ Pod {pod_name} recovered to Running state\n")
        
    elif expected_recovery == 'service_endpoints':
        # Find service associated with target label
        label_selector = target_label
        services_list = core_v1.list_namespaced_service(
            namespace=TEST_NAMESPACE,
            label_selector=label_selector
        )
        
        assert services_list.items, f"No services found with label '{label_selector}'"
        service_name = services_list.items[0].metadata.name
        
        # Determine minimum endpoints based on StatefulSet replicas
        apps_list = apps_v1.list_namespaced_stateful_set(
            namespace=TEST_NAMESPACE,
            label_selector=label_selector
        )
        min_endpoints = apps_list.items[0].spec.replicas if apps_list.items else 1
        
        wait_for_service_recovery(
            core_v1=core_v1,
            namespace=TEST_NAMESPACE,
            service_name=service_name,
            min_endpoints=min_endpoints,
            timeout_seconds=mttr_seconds
        )
        print(f"✓ Service {service_name} recovered with {min_endpoints}+ endpoints\n")
        
    else:
        pytest.fail(f"Unknown expected_recovery type: {expected_recovery}")
    
    print(f"{'='*80}")
    print(f"✓ DR Scenario PASSED: {scenario['scenario']}")
    print(f"{'='*80}\n")

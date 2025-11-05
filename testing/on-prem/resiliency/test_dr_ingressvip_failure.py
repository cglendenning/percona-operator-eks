"""
Disaster Recovery Test: Ingress/VIP failure (HAProxy/ProxySQL service unreachable)

Business Impact: High (app down though DB healthy)
Likelihood: Medium
RTO Target: 10–30 minutes
RPO Target: 0

Delete ProxySQL pod and verify service endpoints recover
"""
import pytest
from kubernetes import client
from tests.resiliency.chaos_integration import trigger_chaos_experiment, wait_for_chaos_completion
from tests.resiliency.helpers import (
    wait_for_cluster_recovery,
    wait_for_statefulset_recovery,
    wait_for_service_recovery,
    wait_for_pod_recovery
)
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, CHAOS_NAMESPACE


@pytest.mark.dr
def test_ingressvip_failure(core_v1, apps_v1, custom_objects_v1):
    """
    Delete ProxySQL pod and verify service endpoints recover
    
    Scenario: Ingress/VIP failure (HAProxy/ProxySQL service unreachable)
    Detection Signals: Health checks fail; 502/503; service endpoints empty
    Primary Recovery: Fail traffic to alternate service/ingress; fix Service/Endpoints
    """
    print(f"\n{'='*80}")
    print(f"DR Scenario: Ingress/VIP failure (HAProxy/ProxySQL service unreachable)")
    print(f"Business Impact: High (app down though DB healthy) | Likelihood: Medium")
    print(f"RTO: 10–30 minutes | RPO: 0")
    print(f"{'='*80}\n")
    
    # Step 1: Trigger chaos experiment
    print(f"[1/3] Triggering chaos: pod-delete")
    print(f"      Target: statefulset with label 'app.kubernetes.io/component=proxysql'")
    print(f"      Duration: 60s, Interval: 10s\n")
    
    engine_name = trigger_chaos_experiment(
        experiment_type="pod-delete",
        app_namespace=TEST_NAMESPACE,
        app_label="app.kubernetes.io/component=proxysql",
        app_kind="statefulset",
        total_chaos_duration=60,
        chaos_interval=10
    )
    
    assert engine_name is not None, "Failed to trigger chaos experiment"
    print(f"✓ Chaos engine created: {engine_name}\n")
    
    # Step 2: Wait for chaos to complete
    print(f"[2/3] Waiting for chaos experiment to complete...")
    wait_for_chaos_completion(
        chaos_namespace=CHAOS_NAMESPACE,
        engine_name=engine_name,
        timeout=180
    )
    print(f"✓ Chaos experiment completed\n")
    
    # Step 3: Verify recovery based on expected_recovery type
    print(f"[3/3] Verifying recovery: service_endpoints")
    print(f"      Timeout: 600s, Poll interval: 15s\n")
    
    # Find service associated with target label
    label_selector = "app.kubernetes.io/component=proxysql"
    services_list = core_v1.list_namespaced_service(
        namespace=TEST_NAMESPACE,
        label_selector=label_selector
    )
    
    assert services_list.items, f"No services found with label '{label_selector}'"
    service_name = services_list.items[0].metadata.name
    
    # Determine minimum endpoints from StatefulSet replicas
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
        timeout_seconds=600
    )
    print(f"✓ Service {service_name} recovered with {min_endpoints}+ endpoints\n")
    
    print(f"{'='*80}")
    print(f"✓ DR Scenario PASSED: Ingress/VIP failure (HAProxy/ProxySQL service unreachable)")
    print(f"{'='*80}\n")

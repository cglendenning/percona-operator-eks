"""
Disaster Recovery Test: Single MySQL pod failure (container crash / OOM)

Business Impact: Low
Likelihood: Medium
RTO Target: 5–10 minutes
RPO Target: 0 (no data loss)

Delete a single PXC pod and verify cluster recovers
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
def test_single_mysql_pod_failure(core_v1, apps_v1, custom_objects_v1):
    """
    Delete a single PXC pod and verify cluster recovers
    
    Scenario: Single MySQL pod failure (container crash / OOM)
    Detection Signals: Pod CrashLoopBackOff; PXC node missing; HAProxy/ProxySQL health check fails
    Primary Recovery: K8s restarts pod; Percona Operator re‑joins PXC node automatically
    """
    print(f"\n{'='*80}")
    print(f"DR Scenario: Single MySQL pod failure (container crash / OOM)")
    print(f"Business Impact: Low | Likelihood: Medium")
    print(f"RTO: 5–10 minutes | RPO: 0 (no data loss)")
    print(f"{'='*80}\n")
    
    # Step 1: Trigger chaos experiment
    print(f"[1/3] Triggering chaos: pod-delete")
    print(f"      Target: statefulset with label 'app.kubernetes.io/component=pxc'")
    print(f"      Duration: 60s, Interval: 10s\n")
    
    engine_name = trigger_chaos_experiment(
        experiment_type="pod-delete",
        app_namespace=TEST_NAMESPACE,
        app_label="app.kubernetes.io/component=pxc",
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
    print(f"[3/3] Verifying recovery: cluster_ready")
    print(f"      Timeout: 600s, Poll interval: 15s\n")
    
    wait_for_cluster_recovery(
        custom_objects_v1=custom_objects_v1,
        namespace=TEST_NAMESPACE,
        cluster_name=TEST_CLUSTER_NAME,
        expected_nodes=3,
        timeout_seconds=600
    )
    print(f"✓ Cluster {TEST_CLUSTER_NAME} recovered to ready state\n")
    
    print(f"{'='*80}")
    print(f"✓ DR Scenario PASSED: Single MySQL pod failure (container crash / OOM)")
    print(f"{'='*80}\n")

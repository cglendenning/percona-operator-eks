"""
Disaster Recovery Test: Kubernetes worker node failure (VM host crash)

Business Impact: Medium
Likelihood: Medium
RTO Target: 10–20 minutes
RPO Target: 0

Drain a node hosting PXC pods and verify rescheduling and recovery
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
def test_kubernetes_worker_node_failure(core_v1, apps_v1, custom_objects_v1):
    """
    Drain a node hosting PXC pods and verify rescheduling and recovery
    
    Scenario: Kubernetes worker node failure (VM host crash)
    Detection Signals: Node NotReady; pod evictions; HAProxy backend down
    Primary Recovery: Pods rescheduled by K8s; PXC node re‑joins cluster
    """
    print(f"\n{'='*80}")
    print(f"DR Scenario: Kubernetes worker node failure (VM host crash)")
    print(f"Business Impact: Medium | Likelihood: Medium")
    print(f"RTO: 10–20 minutes | RPO: 0")
    print(f"{'='*80}\n")
    
    # Step 1: Trigger chaos experiment
    print(f"[1/3] Triggering chaos: node-drain")
    print(f"      Target: statefulset with label 'app.kubernetes.io/component=pxc'")
    print(f"      Duration: 300s, Interval: 60s\n")
    
    engine_name = trigger_chaos_experiment(
        experiment_type="node-drain",
        app_namespace=TEST_NAMESPACE,
        app_label="app.kubernetes.io/component=pxc",
        app_kind="statefulset",
        total_chaos_duration=300,
        chaos_interval=60
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
    print(f"      Timeout: 1200s, Poll interval: 30s\n")
    
    wait_for_cluster_recovery(
        custom_objects_v1=custom_objects_v1,
        namespace=TEST_NAMESPACE,
        cluster_name=TEST_CLUSTER_NAME,
        expected_nodes=3,
        timeout_seconds=1200
    )
    print(f"✓ Cluster {TEST_CLUSTER_NAME} recovered to ready state\n")
    
    print(f"{'='*80}")
    print(f"✓ DR Scenario PASSED: Kubernetes worker node failure (VM host crash)")
    print(f"{'='*80}\n")

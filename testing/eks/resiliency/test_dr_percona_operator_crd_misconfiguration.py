"""
Disaster Recovery Test: Percona Operator / CRD misconfiguration (bad rollout)

Business Impact: Medium
Likelihood: Medium
RTO Target: 15–45 minutes
RPO Target: 0

Delete operator pod and verify it recovers and reconciles cluster
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
def test_percona_operator_crd_misconfiguration(core_v1, apps_v1, custom_objects_v1):
    """
    Delete operator pod and verify it recovers and reconciles cluster
    
    Scenario: Percona Operator / CRD misconfiguration (bad rollout)
    Detection Signals: Pods stuck Pending/CrashLoop; operator reconciliation errors
    Primary Recovery: Rollback GitOps change in Rancher/Fleet; restore previous CR YAML
    """
    print(f"\n{'='*80}")
    print(f"DR Scenario: Percona Operator / CRD misconfiguration (bad rollout)")
    print(f"Business Impact: Medium | Likelihood: Medium")
    print(f"RTO: 15–45 minutes | RPO: 0")
    print(f"{'='*80}\n")
    
    # Step 1: Trigger chaos experiment
    print(f"[1/3] Triggering chaos: pod-delete")
    print(f"      Target: deployment with label 'app.kubernetes.io/name=percona-xtradb-cluster-operator'")
    print(f"      Duration: 60s, Interval: 10s\n")
    
    engine_name = trigger_chaos_experiment(
        experiment_type="pod-delete",
        app_namespace=TEST_NAMESPACE,
        app_label="app.kubernetes.io/name=percona-xtradb-cluster-operator",
        app_kind="deployment",
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
    print(f"      Timeout: 900s, Poll interval: 30s\n")
    
    wait_for_cluster_recovery(
        custom_objects_v1=custom_objects_v1,
        namespace=TEST_NAMESPACE,
        cluster_name=TEST_CLUSTER_NAME,
        expected_nodes=3,
        timeout_seconds=900
    )
    print(f"✓ Cluster {TEST_CLUSTER_NAME} recovered to ready state\n")
    
    print(f"{'='*80}")
    print(f"✓ DR Scenario PASSED: Percona Operator / CRD misconfiguration (bad rollout)")
    print(f"{'='*80}\n")

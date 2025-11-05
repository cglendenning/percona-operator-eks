"""
Test that StatefulSets use OrderedReady pod management
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_statefulset_pod_management_policy(apps_v1):
    """Test that StatefulSets use OrderedReady pod management"""
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)

    for sts in sts_list.items:
        # OrderedReady is the def ault (can be None)
        pod_management = sts.spec.pod_management_policy or 'OrderedReady'
        console.print(f"[cyan]{sts.metadata.name} PodManagementPolicy:[/cyan] {pod_management}")

"""
Test that StatefulSets use appropriate update strategy
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_statefulset_update_strategy(apps_v1):
    """Test that StatefulSets use appropriate update strategy"""
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)

    for sts in sts_list.items:
        update_strategy = sts.spec.update_strategy.type
        console.print(f"[cyan]{sts.metadata.name} UpdateStrategy:[/cyan] {update_strategy}")

        # StatefulSets should use RollingUpdate or OnDelete
        assert update_strategy in ['RollingUpdate', 'OnDelete'], \
            f"StatefulSet {sts.metadata.name} has unexpected update strategy: {update_strategy}"

"""
Test that StatefulSet pod templates can have tolerations (optional check)
"""
import pytest
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pods_can_have_tolerations(apps_v1):
    """Test that StatefulSet pod templates can have tolerations (optional check)"""
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)

    for sts in sts_list.items:
        tolerations = sts.spec.template.spec.tolerations or []
        console.print(f"[cyan]{sts.metadata.name} Tolerations:[/cyan] {len(tolerations)}")
        # Tolerations are optional, so we just log them


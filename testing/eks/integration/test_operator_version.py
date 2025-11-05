"""
Test that Percona Operator is installed and check its version
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_operator_version(core_v1):
    """Test that Percona Operator is installed and check its version"""
    # Try multiple label selectors for operator pods (helm chart uses pxc-operator)
    pods = None
    for label in ['app.kubernetes.io/name=pxc-operator', 
                  'app.kubernetes.io/name=percona-xtradb-cluster-operator',
                  'app.kubernetes.io/component=operator']:
        try:
            result = core_v1.list_namespaced_pod(
                namespace=TEST_NAMESPACE,
                label_selector=label
            )
            if len(result.items) > 0:
                pods = result
                break
        except:
            continue

    # Fallback: get all pods and filter by name pattern
    if not pods or len(pods.items) == 0:
        all_pods = core_v1.list_namespaced_pod(namespace=TEST_NAMESPACE)
        operator_pods = [p for p in all_pods.items if 'operator' in p.metadata.name and 'pxc' in p.metadata.name]
        if operator_pods:
            # Create a mock result object with items attribute
            class MockResult:
                def __init__(self, items):
                    self.items = items
            pods = MockResult(operator_pods)

    assert pods and len(pods.items) > 0, "Percona Operator pod not found"

    operator_pod = pods.items[0]
    image = operator_pod.spec.containers[0].image

    console.print(f"[cyan]Operator Image:[/cyan] {image}")

    # Verify operator pod is running
    assert operator_pod.status.phase == 'Running', \
        f"Operator pod is not Running (status: {operator_pod.status.phase})"

    # Check image tag exists
    assert ':' in image, f"Operator image missing tag: {image}"

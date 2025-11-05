"""
Test ProxySQL pod image versions are consistent
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_image_version(core_v1):
    """Test ProxySQL pod image versions are consistent"""
    pods = core_v1.list_namespaced_pod(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=proxysql'
    )

    assert len(pods.items) > 0, "No ProxySQL pods found"

    images = set()
    for pod in pods.items:
        for container in pod.spec.containers:
            images.add(container.image)
            console.print(f"[cyan]ProxySQL Pod {pod.metadata.name} Image:[/cyan] {container.image}")

    # All ProxySQL pods should use the same image version
    assert len(images) == 1, \
        f"ProxySQL pods are using different image versions: {images}"

    # Verify image has a version tag (expected: percona/proxysql2:2.7.3 or similar)
    image = list(images)[0]
    assert 'proxysql' in image.lower(), f"Expected ProxySQL image, got: {image}"
    assert ':' in image and image.split(':')[1] not in ('latest', ''), \
        f"ProxySQL image should have a specific version tag: {image}"

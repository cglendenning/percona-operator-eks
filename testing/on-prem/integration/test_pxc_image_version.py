"""
Test PXC pod image versions are consistent
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_image_version(core_v1):
    """Test PXC pod image versions are consistent"""
    pods = core_v1.list_namespaced_pod(
        namespace=TEST_NAMESPACE,
        label_selector='app.kubernetes.io/component=pxc'
    )

    assert len(pods.items) > 0, "No PXC pods found"

    images = set()
    for pod in pods.items:
        for container in pod.spec.containers:
            if 'pxc' in container.name.lower() or 'mysql' in container.name.lower():
                images.add(container.image)
                console.print(f"[cyan]PXC Pod {pod.metadata.name} Image:[/cyan] {container.image}")

    # All PXC pods should use the same image version
    assert len(images) == 1, \
        f"PXC pods are using different image versions: {images}"

    # Verify image has a version tag
    image = list(images)[0]
    assert ':' in image and image.split(':')[1] not in ('latest', ''), \
        f"PXC image should have a specific version tag, not 'latest' or empty: {image}"

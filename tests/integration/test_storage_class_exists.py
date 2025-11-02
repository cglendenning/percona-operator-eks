"""
Test that gp3 storage class exists
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_storage_class_exists(storage_v1):
    """Test that gp3 storage class exists"""
    try:
        sc = storage_v1.read_storage_class(name='gp3')
        console.print(f"[cyan]StorageClass gp3:[/cyan] {sc.provisioner}")

        assert sc.provisioner == 'ebs.csi.aws.com', \
            f"StorageClass gp3 has wrong provisioner: {sc.provisioner}"

        # Check allowVolumeExpansion is enabled
        assert sc.allow_volume_expansion is True, \
            "StorageClass gp3 should allow volume expansion"
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail("StorageClass 'gp3' not found")
        raise

"""
Test that gp3 storage class exists
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES, ON_PREM, STORAGE_CLASS_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_storage_class_exists(storage_v1):
    """Test that expected storage class exists (gp3 on EKS, env-defined on on-prem)."""
    try:
        name = STORAGE_CLASS_NAME if ON_PREM else 'gp3'
        sc = storage_v1.read_storage_class(name=name)
        console.print(f"[cyan]StorageClass {name}:[/cyan] {sc.provisioner}")

        if not ON_PREM:
            assert sc.provisioner == 'ebs.csi.aws.com', \
                f"StorageClass {name} has wrong provisioner: {sc.provisioner}"

        # Check allowVolumeExpansion is enabled
        assert sc.allow_volume_expansion is True, \
            f"StorageClass {name} should allow volume expansion"
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"StorageClass '{name}' not found")
        raise

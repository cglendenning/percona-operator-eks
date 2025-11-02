"""
Test that gp3 storage class has correct parameters
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_storage_class_parameters(storage_v1):
    """Test that gp3 storage class has correct parameters"""
    sc = storage_v1.read_storage_class(name='gp3')

    params = sc.parameters or {}

    # Check encryption is enabled
    assert params.get('encrypted') == 'true' or params.get('encrypted') == 'True', \
        "StorageClass gp3 should have encryption enabled"

    # Check volume binding mode
    assert sc.volume_binding_mode == 'WaitForFirstConsumer', \
        f"StorageClass gp3 should use WaitForFirstConsumer binding mode, got: {sc.volume_binding_mode}"

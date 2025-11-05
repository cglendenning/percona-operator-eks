"""
Test that gp3 storage class has correct parameters
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES, ON_PREM, STORAGE_CLASS_NAME
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_storage_class_parameters(storage_v1):
    """Test that expected storage class has correct parameters (encryption, binding mode)."""
    name = STORAGE_CLASS_NAME if ON_PREM else 'gp3'
    sc = storage_v1.read_storage_class(name=name)

    params = sc.parameters or {}

    # Check encryption is enabled
    # Encryption recommended when supported; some on-prem provisioners may not expose this param
    if not ON_PREM:
        assert params.get('encrypted') == 'true' or params.get('encrypted') == 'True', \
            f"StorageClass {name} should have encryption enabled"

    # Check volume binding mode
    assert sc.volume_binding_mode == 'WaitForFirstConsumer', \
        f"StorageClass {name} should use WaitForFirstConsumer binding mode, got: {sc.volume_binding_mode}"

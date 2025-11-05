"""
Test that backup credentials secret exists
"""
import pytest
from kubernetes import client
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_backup_secret_exists(core_v1):
    """Test that backup credentials secret exists"""
    secrets = core_v1.list_namespaced_secret(
        namespace=TEST_NAMESPACE,
        label_selector=None
    )

    backup_secrets = [
        s for s in secrets.items
        if 'backup' in s.metadata.name.lower() and ('minio' in s.metadata.name.lower() or 's3' in s.metadata.name.lower())
    ]

    assert len(backup_secrets) > 0, \
        "Backup credentials secret not found (expected: percona-backup-minio-credentials or percona-backup-s3-credentials)"

    secret = backup_secrets[0]
    console.print(f"[cyan]Backup Secret Found:[/cyan] {secret.metadata.name}")

    # Verify secret has required keys
    if 'minio' in secret.metadata.name.lower():
        required_keys = ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_ENDPOINT']
    else:
        required_keys = ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY']

    data = secret.data or {}
    string_data = secret.string_data or {}
    # Check both data (base64 encoded) and string_data (plain text)
    all_data = {**{k: v for k, v in data.items()}, **{k: v for k, v in string_data.items()}}

    for key in required_keys:
        assert key in all_data, \
            f"Backup secret {secret.metadata.name} missing required key: {key}"

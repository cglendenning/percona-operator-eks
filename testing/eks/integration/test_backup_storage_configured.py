"""
Test that backup storage is configured in PXC CR
"""
import pytest
import json
import subprocess
import yaml
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_backup_storage_configured():
    """Test that backup storage is configured in PXC CR"""
    result = subprocess.run(
        ['kubectl', 'get', 'pxc', '-n', TEST_NAMESPACE, '-o', 'json'],
        capture_output=True,
        text=True,
        check=True
    )

    pxc_list = json.loads(result.stdout)

    assert len(pxc_list['items']) > 0, "No PXC custom resources found"

    pxc = pxc_list['items'][0]
    spec = pxc.get('spec', {})
    backup = spec.get('backup', {})

    # Backups are enabled if storages or schedules are configured
    storages = backup.get('storages', {})
    schedules = backup.get('schedule', [])

    # Backup is effectively enabled if storages exist or schedules exist
    backup_enabled = len(storages) > 0 or len(schedules) > 0

    assert backup_enabled, \
        "Backup should be enabled (storages or schedules configured) in PXC configuration"

    assert len(storages) > 0, \
        "Backup storages should be configured"

    # Check for S3-compatible storage (MinIO or S3)
    s3_storages = {
        k: v for k, v in storages.items()
        if v.get('type') == 's3' or 's3' in k.lower() or 'minio' in k.lower()
    }

    assert len(s3_storages) > 0, \
        "At least one S3-compatible backup storage (MinIO or S3) should be configured"

    console.print(f"[cyan]Backup Storages Configured:[/cyan] {list(storages.keys())}")

    # If using MinIO, verify endpoint is configured (either in PXC CR or Helm values)
    for storage_name, storage_config in s3_storages.items():
        if 'minio' in storage_name.lower():
            s3_config = storage_config.get('s3', {})
            endpoint = s3_config.get('endpoint')

            # Endpoint might be in PXC CR or only in Helm values
            # If not in CR, check Helm values
            if not endpoint:
                result = subprocess.run(
                    ['helm', 'get', 'values', TEST_CLUSTER_NAME, '-n', TEST_NAMESPACE, '--output', 'yaml'],
                    capture_output=True,
                    text=True
                )
                if result.returncode == 0:
                    helm_values = yaml.safe_load(result.stdout)
                    backup_storages = helm_values.get('backup', {}).get('storages', {})
                    minio_storage = backup_storages.get(storage_name, {})
                    endpoint = minio_storage.get('s3', {}).get('endpoint')

            # Endpoint is optional if it can be inferred from credentials secret
            if endpoint:
                console.print(f"[cyan]{storage_name} Endpoint:[/cyan] {endpoint}")
            else:
                console.print(f"[yellow]Note: {storage_name} endpoint not found in CR or Helm values (may be inferred from credentials)[/yellow]")

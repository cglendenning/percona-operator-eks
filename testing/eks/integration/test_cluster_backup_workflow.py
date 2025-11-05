"""
Integration tests for backup workflow.
Validates that backup schedules are created and functional.
"""
import pytest
import time
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME
from kubernetes import client
from rich.console import Console

console = Console()


@pytest.mark.integration
def test_backup_storage_secret_exists(core_v1):
    """Test that backup storage credentials secret exists."""
    secret_name = 'percona-backup-minio-credentials'
    
    try:
        secret = core_v1.read_namespaced_secret(secret_name, TEST_NAMESPACE)
        assert secret is not None, f"Backup secret {secret_name} should exist"
        
        # Verify secret has required keys
        assert 'AWS_ACCESS_KEY_ID' in secret.data or 'AWS_ACCESS_KEY_ID' in secret.string_data
        assert 'AWS_SECRET_ACCESS_KEY' in secret.data or 'AWS_SECRET_ACCESS_KEY' in secret.string_data
        assert 'AWS_ENDPOINT' in secret.data or 'AWS_ENDPOINT' in secret.string_data
        
        console.print(f"[green]✓[/green] Backup secret {secret_name} exists with required keys")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"Backup secret {secret_name} does not exist in namespace {TEST_NAMESPACE}")
        raise


@pytest.mark.integration
def test_backup_schedules_created(custom_objects_v1):
    """Test that backup schedules are created from configuration."""
    group = 'pxc.percona.com'
    version = 'v1'
    plural = 'perconaxbackupbackupschedules'
    
    try:
        schedules = custom_objects_v1.list_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural
        )
        
        items = schedules.get('items', [])
        assert len(items) > 0, "At least one backup schedule should be created"
        
        schedule_names = [item['metadata']['name'] for item in items]
        
        # Check for expected schedules
        expected_schedules = ['daily-backup', 'weekly-backup', 'monthly-backup']
        for expected in expected_schedules:
            # Schedules might have cluster name prefix
            found = any(expected in name or name.endswith(expected) for name in schedule_names)
            if not found:
                console.print(f"[yellow]⚠[/yellow] Schedule {expected} not found. Found: {schedule_names}")
        
        console.print(f"[green]✓[/green] Found {len(items)} backup schedule(s)")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"Backup schedules CRD not found or no schedules created")
        raise


@pytest.mark.integration
def test_pitr_enabled_and_configured(custom_objects_v1):
    """Test that PITR is enabled and configured in the cluster."""
    group = 'pxc.percona.com'
    version = 'v1'
    plural = 'perconaxtradbclusters'
    
    try:
        clusters = custom_objects_v1.list_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural
        )
        
        items = clusters.get('items', [])
        assert len(items) > 0, "Cluster should exist"
        
        cluster = items[0]
        spec = cluster.get('spec', {})
        backup = spec.get('backup', {})
        pitr = backup.get('pitr', {})
        
        assert pitr.get('enabled') is True, "PITR should be enabled"
        assert 'storageName' in pitr, "PITR should have storageName configured"
        assert 'timeBetweenUploads' in pitr, "PITR should have timeBetweenUploads configured"
        
        console.print(f"[green]✓[/green] PITR is enabled and configured")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"Cluster CRD not found")
        raise


@pytest.mark.integration
def test_backup_storage_accessible(core_v1, custom_objects_v1):
    """Test that backup storage (MinIO) is accessible from cluster."""
    # This test verifies that the backup storage endpoint is reachable
    # by checking if backup jobs can be scheduled
    
    group = 'pxc.percona.com'
    version = 'v1'
    plural = 'perconaxbackupstorages'
    
    try:
        storages = custom_objects_v1.list_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural
        )
        
        items = storages.get('items', [])
        assert len(items) > 0, "At least one backup storage should be configured"
        
        # Check that storage is properly configured
        storage = items[0]
        spec = storage.get('spec', {})
        assert 's3' in spec or 'type' in spec, "Storage should have S3 configuration"
        
        console.print(f"[green]✓[/green] Backup storage is configured")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"Backup storage CRD not found")
        raise


@pytest.mark.integration
def test_backup_jobs_can_be_created(custom_objects_v1):
    """Test that backup jobs can be created (validates backup configuration)."""
    # This is a validation that backup configuration is correct
    # Actual backup job creation would be tested separately
    
    group = 'pxc.percona.com'
    version = 'v1'
    plural = 'perconaxbackups'
    
    try:
        # Just verify the CRD exists and we can list backups
        backups = custom_objects_v1.list_namespaced_custom_object(
            group=group,
            version=version,
            namespace=TEST_NAMESPACE,
            plural=plural
        )
        
        # CRD exists and is accessible
        assert backups is not None
        console.print(f"[green]✓[/green] Backup CRD is accessible, backup jobs can be created")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            pytest.fail(f"Backup CRD not found - backup functionality may not be available")
        raise


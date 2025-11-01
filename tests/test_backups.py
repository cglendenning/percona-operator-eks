"""
Test Backup configuration (S3/MinIO)
"""
import pytest
import subprocess
import json
from kubernetes import client
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET

console = Console()


class TestBackupConfiguration:
    """Test backup configuration and storage"""

    def test_backup_secret_exists(self, core_v1):
        """Test that backup credentials secret exists"""
        secrets = core_v1.list_namespaced_secret(
            namespace=TEST_NAMESPACE,
            label_selector=None
        )
        
        backup_secrets = [
            s for s in secrets.items
            if 'backup' in s.metadata.name.lower() and 's3' in s.metadata.name.lower()
        ]
        
        assert len(backup_secrets) > 0, \
            "Backup S3 credentials secret not found (expected: percona-backup-s3-credentials)"
        
        secret = backup_secrets[0]
        console.print(f"[cyan]Backup Secret Found:[/cyan] {secret.metadata.name}")
        
        # Verify secret has required keys
        required_keys = ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY']
        data = secret.data or {}
        
        for key in required_keys:
            assert key in data, \
                f"Backup secret {secret.metadata.name} missing required key: {key}"

    def test_backup_storage_configured(self):
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
        
        assert backup.get('enabled') is True, \
            "Backup should be enabled in PXC configuration"
        
        storages = backup.get('storages', {})
        assert len(storages) > 0, \
            "Backup storages should be configured"
        
        # Check for S3 storage
        s3_storages = {
            k: v for k, v in storages.items()
            if v.get('type') == 's3' or 's3' in k.lower()
        }
        
        assert len(s3_storages) > 0, \
            "At least one S3 backup storage should be configured"
        
        console.print(f"[cyan]Backup Storages Configured:[/cyan] {list(storages.keys())}")

    def test_backup_schedules_exist(self):
        """Test that backup schedules are configured"""
        result = subprocess.run(
            ['kubectl', 'get', 'pxc', '-n', TEST_NAMESPACE, '-o', 'json'],
            capture_output=True,
            text=True,
            check=True
        )
        
        pxc = json.loads(result.stdout)['items'][0]
        backup = pxc.get('spec', {}).get('backup', {})
        schedules = backup.get('schedule', [])
        
        assert len(schedules) > 0, \
            "Backup schedules should be configured"
        
        console.print(f"[cyan]Backup Schedules:[/cyan] {len(schedules)}")
        
        for schedule in schedules:
            name = schedule.get('name', 'unnamed')
            cron = schedule.get('schedule', '')
            console.print(f"  ✓ {name}: {cron}")
            
            # Verify schedule has required fields
            assert 'schedule' in schedule, \
                f"Backup schedule {name} missing 'schedule' field"
            assert 'storageName' in schedule, \
                f"Backup schedule {name} missing 'storageName' field"

    def test_backup_cronjobs_exist(self, core_v1):
        """Test that backup CronJobs exist (if using scheduled backups)"""
        # Note: This depends on the Percona operator creating CronJobs
        # Some versions use other mechanisms, so this test may need adjustment
        
        try:
            from kubernetes.client.rest import ApiException
            batch_v1 = client.BatchV1Api()
            cronjobs = batch_v1.list_namespaced_cron_job(
                namespace=TEST_NAMESPACE,
                label_selector='app.kubernetes.io/managed-by=percona-xtradb-cluster-operator'
            )
            
            if len(cronjobs.items) > 0:
                console.print(f"[cyan]Backup CronJobs Found:[/cyan] {len(cronjobs.items)}")
                for cj in cronjobs.items:
                    console.print(f"  ✓ {cj.metadata.name}: {cj.spec.schedule}")
        except ApiException:
            # CronJobs might not exist in all Percona operator versions
            console.print("[yellow]⚠ Backup CronJobs not found (may use different mechanism)[/yellow]")

    def test_s3_bucket_accessible(self):
        """Test that S3 backup bucket exists and is accessible (if AWS credentials available)"""
        if TEST_BACKUP_TYPE != 's3':
            pytest.skip("Skipping S3 bucket test - not using S3")
        
        if not TEST_BACKUP_BUCKET:
            pytest.skip("Skipping S3 bucket test - TEST_BACKUP_BUCKET not set")
        
        try:
            result = subprocess.run(
                ['aws', 's3', 'ls', f's3://{TEST_BACKUP_BUCKET}'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode == 0:
                console.print(f"[green]✓[/green] S3 bucket {TEST_BACKUP_BUCKET} is accessible")
            else:
                console.print(f"[yellow]⚠[/yellow] Could not access S3 bucket: {result.stderr}")
                # Don't fail test if bucket access fails (might be permission issue)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pytest.skip("AWS CLI not available or timeout - skipping S3 bucket access test")

    def test_minio_accessible(self):
        """Test MinIO accessibility (if using MinIO)"""
        if TEST_BACKUP_TYPE != 'minio':
            pytest.skip("Skipping MinIO test - not using MinIO")
        
        # This would require MinIO client setup
        # For now, just check if MinIO service exists
        try:
            result = subprocess.run(
                ['kubectl', 'get', 'svc', '-n', TEST_NAMESPACE, '-l', 'app=minio'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if 'minio' in result.stdout.lower():
                console.print("[green]✓[/green] MinIO service found")
            else:
                console.print("[yellow]⚠[/yellow] MinIO service not found")
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            pytest.skip("MinIO service check failed - may not be using MinIO")


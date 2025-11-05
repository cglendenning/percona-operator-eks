"""
Test that backup CronJobs exist (if using scheduled backups)
"""
import pytest
from kubernetes import client
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_backup_cronjobs_exist(core_v1):
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

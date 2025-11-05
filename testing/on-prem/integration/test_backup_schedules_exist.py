"""
Test that backup schedules are configured
"""
import pytest
import json
import subprocess
from kubernetes import client
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_backup_schedules_exist():
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

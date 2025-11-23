"""
Unit tests for backup configuration validation.
Validates backup schedules, retention, PITR, and storage configuration per Percona v1.18 best practices.
"""
import pytest
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_complete_backup_strategy_configured():
    """Test that a complete backup strategy is configured: storage, PITR, and scheduled backups."""
    values, path = get_values_for_test()
    
    backup = values.get('backup', {})
    
    # 1. Verify storage is configured
    storages = backup.get('storages', {})
    log_check("Backup storages must be configured", "len > 0", f"{len(storages)} storages", source=path)
    assert len(storages) > 0, "At least one backup storage must be configured"
    
    # Verify minio storage exists with required s3 config
    assert 'minio' in storages, "minio storage must be configured"
    storage = storages['minio']
    assert storage['type'] == 's3', "Storage type should be s3 (S3-compatible)"
    s3_config = storage['s3']
    for key in ['bucket', 'region', 'endpointUrl', 'credentialsSecret']:
        assert key in s3_config, f"s3 config must include {key}"
    
    # 2. Check PITR is enabled (for continuous binary log shipping)
    pitr = backup.get('pitr', {})
    pitr_enabled = pitr.get('enabled', False)
    log_check("PITR must be enabled for point-in-time recovery", "True", f"{pitr_enabled}", source=path)
    assert pitr_enabled is True, "PITR must be enabled for continuous backup and point-in-time recovery"
    
    # Verify PITR timeBetweenUploads is reasonable (30-300 seconds for good RPO)
    time_between_uploads = pitr.get('timeBetweenUploads', 0)
    log_check("PITR timeBetweenUploads between 30-300s", "30..300", f"{time_between_uploads}", source=path)
    assert 30 <= time_between_uploads <= 300, \
        "PITR timeBetweenUploads should be between 30-300 seconds for reasonable RPO"
    
    # 3. Check scheduled backups exist (for base backups)
    schedules = backup.get('schedule', [])
    log_check("At least one backup schedule must be configured", ">= 1", f"{len(schedules)}", source=path)
    assert len(schedules) >= 1, \
        "At least one scheduled backup is required - PITR needs base backups to restore from"
    
    # 4. Verify PITR and schedules reference valid storage
    pitr_storage = pitr.get('storageName')
    schedule_storages = [s.get('storageName') for s in schedules]
    
    log_check(
        "PITR and scheduled backups should use configured storage",
        "storage names match available storages",
        f"PITR storage={pitr_storage}, schedule storages={schedule_storages}, available={list(storages.keys())}",
        source=path
    )
    
    if pitr_storage:
        assert pitr_storage in storages, f"PITR storage '{pitr_storage}' must exist in backup.storages"
    
    for schedule in schedules:
        storage_name = schedule.get('storageName')
        assert storage_name in storages, f"Schedule storage '{storage_name}' must exist in backup.storages"


@pytest.mark.unit
def test_backup_schedules_valid_configuration():
    """Test that backup schedules have valid retention policies."""
    values, path = get_values_for_test()
    
    schedules = values['backup'].get('schedule', [])
    assert len(schedules) > 0, "At least one backup schedule is required"
    
    for schedule in schedules:
        schedule_name = schedule.get('name', 'unknown')
        
        # Verify schedule has required fields
        assert 'schedule' in schedule, f"Schedule '{schedule_name}' must have a cron schedule"
        assert 'retention' in schedule, f"Schedule '{schedule_name}' must have retention policy"
        assert 'storageName' in schedule, f"Schedule '{schedule_name}' must reference a storage"
        
        # Validate cron format (5 fields: minute hour day month weekday)
        cron_parts = schedule['schedule'].split()
        assert len(cron_parts) == 5, f"Schedule '{schedule_name}' has invalid cron format: {schedule['schedule']}"
        
        # Validate retention policy
        retention = schedule['retention']
        assert retention['type'] == 'count', f"Schedule '{schedule_name}' retention type should be 'count'"
        assert 'count' in retention, f"Schedule '{schedule_name}' must have retention count"
        assert retention['count'] > 0, f"Schedule '{schedule_name}' retention count must be positive"
        
        # deleteFromStorage should be enabled to prevent storage bloat
        assert retention.get('deleteFromStorage') is True, \
            f"Schedule '{schedule_name}' should have deleteFromStorage enabled"




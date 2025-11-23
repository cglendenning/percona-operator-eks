"""
Unit tests for backup configuration validation.
Validates backup schedules, retention, PITR, and storage configuration per Percona v1.18 best practices.
"""
import os
import yaml
import pytest
import re
from conftest import log_check, get_values_for_test
from datetime import datetime


def parse_cron_schedule(schedule):
    """Parse cron schedule and validate format."""
    # Cron format: minute hour day-of-month month day-of-week
    parts = schedule.split()
    assert len(parts) == 5, f"Invalid cron format: {schedule}"
    return {
        'minute': parts[0],
        'hour': parts[1],
        'day_of_month': parts[2],
        'month': parts[3],
        'day_of_week': parts[4],
    }


@pytest.mark.unit
def test_backup_configured():
    """Test that backup storage is configured (Percona operator has no backup.enabled field)."""
    values, path = get_values_for_test()
    
    # Percona operator doesn't have backup.enabled - backups are "enabled" by having storages configured
    backup = values.get('backup', {})
    storages = backup.get('storages', {})
    
    log_check("Backup storages must be configured", "len > 0", f"{len(storages)} storages", source=path)
    assert len(storages) > 0, "At least one backup storage must be configured for backups to work"


@pytest.mark.unit
def test_complete_backup_strategy_configured():
    """Test that a complete backup strategy is configured: PITR + scheduled backups for proper DR."""
    values, path = get_values_for_test()
    
    backup = values.get('backup', {})
    
    # Check PITR is enabled (for continuous binary log shipping)
    pitr = backup.get('pitr', {})
    pitr_enabled = pitr.get('enabled', False)
    log_check("PITR must be enabled for point-in-time recovery", "True", f"{pitr_enabled}", source=path)
    assert pitr_enabled is True, "PITR must be enabled for continuous backup and point-in-time recovery"
    
    # Check scheduled backups exist (for base backups)
    schedules = backup.get('schedule', [])
    log_check("Scheduled backups must be configured", "len > 0", f"{len(schedules)} schedules", source=path)
    assert len(schedules) > 0, \
        "Scheduled backups are required for proper DR strategy - PITR needs base backups to restore from"
    
    # Verify storage is configured for both
    storages = backup.get('storages', {})
    assert len(storages) > 0, "Backup storage must be configured"
    
    # Best practice: should have PITR storage name matching a schedule storage
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
def test_pitr_enabled():
    """Test that Point-in-Time Recovery (PITR) is enabled."""
    values, path = get_values_for_test()
    
    log_check("PITR must be enabled", "True", f"{values['backup']['pitr']['enabled']}", source=path); assert values['backup']['pitr']['enabled'] is True, "PITR must be enabled for point-in-time recovery"


@pytest.mark.unit
def test_pitr_time_between_uploads():
    """Test that PITR timeBetweenUploads is configured appropriately."""
    values, path = get_values_for_test()
    
    time_between_uploads = values['backup']['pitr']['timeBetweenUploads']
    
    # Should be between 30-300 seconds for reasonable RPO
    # 60 seconds is a good balance
    log_check("PITR timeBetweenUploads between 30-300s", "30..300", f"{time_between_uploads}", source=path)
    assert 30 <= time_between_uploads <= 300, \
        "PITR timeBetweenUploads should be between 30-300 seconds for reasonable RPO"


@pytest.mark.unit
def test_backup_storage_configuration():
    """Test that backup storage is properly configured."""
    values, path = get_values_for_test()
    
    storages = values['backup']['storages']
    log_check("backup.storages must include minio", "present", f"present={'minio' in storages}", source=path); assert 'minio' in storages
    
    storage = storages['minio']
    log_check("backup storage type", "s3", f"{storage['type']}", source=path); assert storage['type'] == 's3', "Storage type should be s3 (S3-compatible)"
    
    s3_config = storage['s3']
    for key in ['bucket','region','endpointUrl','credentialsSecret']:
        log_check(f"s3 config must include {key}", "present", f"present={key in s3_config}", source=path); assert key in s3_config


@pytest.mark.unit
def test_backup_schedules_exist():
    """Test that backup schedules are configured (required for on-prem DR strategy)."""
    values, path = get_values_for_test()
    
    schedules = values['backup'].get('schedule', [])
    
    # On-prem should have scheduled backups as part of complete DR strategy
    log_check("At least one backup schedule must be configured", "> 0", f"{len(schedules)}", source=path)
    assert len(schedules) > 0, \
        "Scheduled backups are required for on-prem DR - PITR alone is not sufficient (needs base backups)"
    


@pytest.mark.unit
def test_daily_backup_schedule():
    """Test daily backup schedule configuration."""
    values, path = get_values_for_test()
    
    schedules = values['backup'].get('schedule', [])
    assert len(schedules) > 0, "Backup schedules are required for on-prem DR strategy"
    
    daily = next((s for s in schedules if s['name'] == 'daily-backup'), None)
    if not daily:
        return  # Daily backup not configured, skip this test
    
    # Validate cron schedule format
    cron = parse_cron_schedule(daily['schedule'])
    log_check("Daily cron", "0 2 * * *", f"{daily['schedule']}", source=path); assert daily['schedule'] == '0 2 * * *', "Daily backup should run at 2 AM"
    
    # Validate retention
    retention = daily['retention']
    log_check("Daily retention.type", "count", f"{retention['type']}", source=path); assert retention['type'] == 'count'
    log_check("Daily retention.count >= 7", ">= 7", f"{retention['count']}", source=path); assert retention['count'] >= 7, "Daily backups should retain at least 7 days"
    log_check("Daily deleteFromStorage", "True", f"{retention.get('deleteFromStorage')}", source=path); assert retention.get('deleteFromStorage') is True, "Old backups should be deleted from storage"
    
    assert daily['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_weekly_backup_schedule():
    """Test weekly backup schedule configuration."""
    values, path = get_values_for_test()
    
    schedules = values['backup'].get('schedule', [])
    assert len(schedules) > 0, "Backup schedules are required for on-prem DR strategy"
    
    weekly = next((s for s in schedules if s['name'] == 'weekly-backup'), None)
    if not weekly:
        return  # Weekly backup not configured, skip this test
    
    # Validate cron schedule format
    cron = parse_cron_schedule(weekly['schedule'])
    log_check("Weekly cron", "0 1 * * 0", f"{weekly['schedule']}", source=path); assert weekly['schedule'] == '0 1 * * 0', "Weekly backup should run Sunday at 1 AM"
    
    # Validate retention
    retention = weekly['retention']
    log_check("Weekly retention.type", "count", f"{retention['type']}", source=path); assert retention['type'] == 'count'
    log_check("Weekly retention.count >= 4", ">= 4", f"{retention['count']}", source=path); assert retention['count'] >= 4, "Weekly backups should retain at least 4 weeks (1 month)"
    log_check("Weekly deleteFromStorage", "True", f"{retention.get('deleteFromStorage')}", source=path); assert retention.get('deleteFromStorage') is True
    
    assert weekly['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_monthly_backup_schedule():
    """Test monthly backup schedule configuration."""
    values, path = get_values_for_test()
    
    schedules = values['backup'].get('schedule', [])
    assert len(schedules) > 0, "Backup schedules are required for on-prem DR strategy"
    
    monthly = next((s for s in schedules if s['name'] == 'monthly-backup'), None)
    if not monthly:
        return  # Monthly backup not configured, skip this test
    
    # Validate cron schedule format
    cron = parse_cron_schedule(monthly['schedule'])
    log_check("Monthly cron", "30 1 1 * *", f"{monthly['schedule']}", source=path); assert monthly['schedule'] == '30 1 1 * *', "Monthly backup should run on 1st of month at 1:30 AM"
    
    # Validate retention
    retention = monthly['retention']
    log_check("Monthly retention.type", "count", f"{retention['type']}", source=path); assert retention['type'] == 'count'
    log_check("Monthly retention.count >= 12", ">= 12", f"{retention['count']}", source=path); assert retention['count'] >= 12, "Monthly backups should retain at least 12 months (1 year)"
    log_check("Monthly deleteFromStorage", "True", f"{retention.get('deleteFromStorage')}", source=path); assert retention.get('deleteFromStorage') is True
    
    assert monthly['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_backup_retention_policy():
    """Test that backup retention policies are appropriate."""
    values, path = get_values_for_test()
    
    schedules = values['backup'].get('schedule', [])
    assert len(schedules) > 0, "Backup schedules are required for on-prem DR strategy"
    
    for schedule in schedules:
        retention = schedule['retention']
        
        # All schedules should use count-based retention
        assert retention['type'] == 'count', "Retention type should be 'count'"
        assert 'count' in retention
        assert retention['count'] > 0, "Retention count must be positive"
        
        # Old backups should be deleted from storage to save space
        assert retention.get('deleteFromStorage') is True, \
            "deleteFromStorage should be enabled to prevent storage bloat"




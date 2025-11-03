"""
Unit tests for backup configuration validation.
Validates backup schedules, retention, PITR, and storage configuration per Percona v1.18 best practices.
"""
import os
import yaml
import pytest
import re
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
def test_backup_enabled():
    """Test that backups are enabled."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    assert values['backup']['enabled'] is True, "Backups must be enabled"


@pytest.mark.unit
def test_pitr_enabled():
    """Test that Point-in-Time Recovery (PITR) is enabled."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    assert values['backup']['pitr']['enabled'] is True, "PITR must be enabled for point-in-time recovery"


@pytest.mark.unit
def test_pitr_time_between_uploads():
    """Test that PITR timeBetweenUploads is configured appropriately."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    time_between_uploads = values['backup']['pitr']['timeBetweenUploads']
    
    # Should be between 30-300 seconds for reasonable RPO
    # 60 seconds is a good balance
    assert 30 <= time_between_uploads <= 300, \
        "PITR timeBetweenUploads should be between 30-300 seconds for reasonable RPO"


@pytest.mark.unit
def test_backup_storage_configuration():
    """Test that backup storage is properly configured."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    storages = values['backup']['storages']
    assert 'minio-backup' in storages
    
    storage = storages['minio-backup']
    assert storage['type'] == 's3', "Storage type should be s3 (S3-compatible)"
    
    s3_config = storage['s3']
    assert 'bucket' in s3_config
    assert 'region' in s3_config
    assert 'endpointUrl' in s3_config
    assert 'credentialsSecret' in s3_config
    assert s3_config.get('forcePathStyle') is True, "MinIO requires forcePathStyle=true"


@pytest.mark.unit
def test_backup_schedules_exist():
    """Test that backup schedules are configured."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    assert len(schedules) > 0, "At least one backup schedule must be configured"
    
    # Should have daily, weekly, and monthly backups
    schedule_names = [s['name'] for s in schedules]
    assert 'daily-backup' in schedule_names
    assert 'weekly-backup' in schedule_names
    assert 'monthly-backup' in schedule_names


@pytest.mark.unit
def test_daily_backup_schedule():
    """Test daily backup schedule configuration."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    daily = next(s for s in schedules if s['name'] == 'daily-backup')
    
    # Validate cron schedule format
    cron = parse_cron_schedule(daily['schedule'])
    assert daily['schedule'] == '0 2 * * *', "Daily backup should run at 2 AM"
    
    # Validate retention
    retention = daily['retention']
    assert retention['type'] == 'count'
    assert retention['count'] >= 7, "Daily backups should retain at least 7 days"
    assert retention.get('deleteFromStorage') is True, "Old backups should be deleted from storage"
    
    assert daily['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_weekly_backup_schedule():
    """Test weekly backup schedule configuration."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    weekly = next(s for s in schedules if s['name'] == 'weekly-backup')
    
    # Validate cron schedule format
    cron = parse_cron_schedule(weekly['schedule'])
    assert weekly['schedule'] == '0 1 * * 0', "Weekly backup should run Sunday at 1 AM"
    
    # Validate retention
    retention = weekly['retention']
    assert retention['type'] == 'count'
    assert retention['count'] >= 4, "Weekly backups should retain at least 4 weeks (1 month)"
    assert retention.get('deleteFromStorage') is True
    
    assert weekly['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_monthly_backup_schedule():
    """Test monthly backup schedule configuration."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    monthly = next(s for s in schedules if s['name'] == 'monthly-backup')
    
    # Validate cron schedule format
    cron = parse_cron_schedule(monthly['schedule'])
    assert monthly['schedule'] == '30 1 1 * *', "Monthly backup should run on 1st of month at 1:30 AM"
    
    # Validate retention
    retention = monthly['retention']
    assert retention['type'] == 'count'
    assert retention['count'] >= 12, "Monthly backups should retain at least 12 months (1 year)"
    assert retention.get('deleteFromStorage') is True
    
    assert monthly['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_backup_retention_policy():
    """Test that backup retention policies are appropriate."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    
    for schedule in schedules:
        retention = schedule['retention']
        
        # All schedules should use count-based retention
        assert retention['type'] == 'count', "Retention type should be 'count'"
        assert 'count' in retention
        assert retention['count'] > 0, "Retention count must be positive"
        
        # Old backups should be deleted from storage to save space
        assert retention.get('deleteFromStorage') is True, \
            "deleteFromStorage should be enabled to prevent storage bloat"


@pytest.mark.unit
def test_backup_storage_secret_reference():
    """Test that backup storage references the correct secret."""
    secret_path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'minio-credentials-secret.yaml')
    values_path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    
    with open(secret_path, 'r', encoding='utf-8') as f:
        secret_content = f.read()
        secret_content = secret_content.replace('{{NAMESPACE}}', 'test')
        secret_content = secret_content.replace('{{AWS_ACCESS_KEY_ID}}', 'test')
        secret_content = secret_content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test')
        secret = yaml.safe_load(secret_content)
    
    with open(values_path, 'r', encoding='utf-8') as f:
        values_content = f.read()
        values_content = values_content.replace('{{NODES}}', '3')
        values = yaml.safe_load(values_content)
    
    secret_name = secret['metadata']['name']
    backup_secret_name = values['backup']['storages']['minio-backup']['s3']['credentialsSecret']
    
    assert secret_name == backup_secret_name, \
        f"Secret name {secret_name} must match backup config {backup_secret_name}"


@pytest.mark.unit
def test_backup_schedule_timezones():
    """Test that backup schedules use appropriate times (off-peak hours)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    
    for schedule in schedules:
        cron = parse_cron_schedule(schedule['schedule'])
        hour = int(cron['hour'])
        
        # Backups should run during off-peak hours (1-3 AM)
        assert 1 <= hour <= 3, \
            f"Backup {schedule['name']} should run during off-peak hours (1-3 AM), not {hour}:00"


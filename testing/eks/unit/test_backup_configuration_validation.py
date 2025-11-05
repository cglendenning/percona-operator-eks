"""
Unit tests for backup configuration validation.
Validates backup schedules, retention, PITR, and storage configuration per Percona v1.18 best practices.
"""
import os
import yaml
import pytest
import re
from conftest import log_check
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
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    log_check("Backups must be enabled", "True", f"{values['backup']['enabled']}", source=path); assert values['backup']['enabled'] is True, "Backups must be enabled"


@pytest.mark.unit
def test_pitr_enabled():
    """Test that Point-in-Time Recovery (PITR) is enabled."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    log_check("PITR must be enabled", "True", f"{values['backup']['pitr']['enabled']}", source=path); assert values['backup']['pitr']['enabled'] is True, "PITR must be enabled for point-in-time recovery"


@pytest.mark.unit
def test_pitr_time_between_uploads():
    """Test that PITR timeBetweenUploads is configured appropriately."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    time_between_uploads = values['backup']['pitr']['timeBetweenUploads']
    
    # Should be between 30-300 seconds for reasonable RPO
    # 60 seconds is a good balance
    log_check("PITR timeBetweenUploads between 30-300s", "30..300", f"{time_between_uploads}", source=path)
    assert 30 <= time_between_uploads <= 300, \
        "PITR timeBetweenUploads should be between 30-300 seconds for reasonable RPO"


@pytest.mark.unit
def test_backup_storage_configuration():
    """Test that backup storage is properly configured."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    storages = values['backup']['storages']
    log_check("backup.storages must include minio-backup", "present", f"present={'minio-backup' in storages}", source=path); assert 'minio-backup' in storages
    
    storage = storages['minio-backup']
    log_check("backup storage type", "s3", f"{storage['type']}", source=path); assert storage['type'] == 's3', "Storage type should be s3 (S3-compatible)"
    
    s3_config = storage['s3']
    for key in ['bucket','region','endpointUrl','credentialsSecret']:
        log_check(f"s3 config must include {key}", "present", f"present={key in s3_config}", source=path); assert key in s3_config
    log_check("s3.forcePathStyle must be True", "True", f"{s3_config.get('forcePathStyle')}", source=path); assert s3_config.get('forcePathStyle') is True, "MinIO requires forcePathStyle=true"


@pytest.mark.unit
def test_backup_schedules_exist():
    """Test that backup schedules are configured."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    log_check("At least one backup schedule configured", "> 0", f"{len(schedules)}", source=path); assert len(schedules) > 0, "At least one backup schedule must be configured"
    
    # Should have daily, weekly, and monthly backups
    schedule_names = [s['name'] for s in schedules]
    log_check("Schedule names should include daily/weekly/monthly", "present", f"{schedule_names}", source=path); assert 'daily-backup' in schedule_names
    assert 'weekly-backup' in schedule_names
    assert 'monthly-backup' in schedule_names


@pytest.mark.unit
def test_daily_backup_schedule():
    """Test daily backup schedule configuration."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    daily = next(s for s in schedules if s['name'] == 'daily-backup')
    
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
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    weekly = next(s for s in schedules if s['name'] == 'weekly-backup')
    
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
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    monthly = next(s for s in schedules if s['name'] == 'monthly-backup')
    
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
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
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
    secret_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'minio-credentials-secret.yaml')
    values_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    
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
    
    log_check("Backup config credentialsSecret matches secret metadata.name", backup_secret_name, secret_name, source=values_path)
    assert secret_name == backup_secret_name, \
        f"Secret name {secret_name} must match backup config {backup_secret_name}"


@pytest.mark.unit
def test_backup_schedule_timezones():
    """Test that backup schedules use appropriate times (off-peak hours)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    schedules = values['backup']['schedule']
    
    for schedule in schedules:
        cron = parse_cron_schedule(schedule['schedule'])
        hour = int(cron['hour'])
        
        # Backups should run during off-peak hours (1-3 AM)
        log_check(f"Backup {schedule['name']} hour should be 1-3", "1..3", f"{hour}", source=path)
        assert 1 <= hour <= 3, \
            f"Backup {schedule['name']} should run during off-peak hours (1-3 AM), not {hour}:00"


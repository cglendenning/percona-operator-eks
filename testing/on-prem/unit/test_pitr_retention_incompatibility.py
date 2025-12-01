"""
Unit test for PITR and retention policy incompatibility.
Validates that backup schedule retention settings are NOT configured when PITR is enabled.

Reference: Percona documentation "Store binary logs for point-in-time recovery" states:
"Disable the retention policy as it is incompatible with point-in-time recovery..."
https://docs.percona.com/percona-operator-for-mysql/pxc/backups-pitr.html

When PITR is enabled, the following backup.schedule fields must NOT be set:
- keep
- retention.type
- retention.count
- retention.deleteFromStorage

This is because automatic retention policies can purge binlogs before they are transferred
to backup storage, breaking the point-in-time recovery process. Instead, storage lifecycle
policies should be used to manage backup retention.
"""
import pytest
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_pitr_retention_incompatibility():
    """
    Test that backup schedule retention settings are NOT configured when PITR is enabled.
    
    How this test gathers information:
    
    1. Loads the values YAML configuration (from Fleet-rendered manifest or values file).
    
    2. Checks if PITR is enabled at: backup.pitr.enabled
    
    3. If PITR is enabled, examines all backup schedules at: backup.schedule[]
    
    4. For each schedule, verifies that none of these retention-related keys are present:
       - keep (deprecated field for backup retention)
       - retention.type (retention policy type)
       - retention.count (number of backups to keep)
       - retention.deleteFromStorage (whether to delete from storage)
    
    5. These keys must be absent (not just set to null/false) because:
       - Retention policies automatically purge binlogs
       - This can break PITR by removing logs before they're backed up
       - Storage lifecycle policies should manage retention instead
       - Explicit absence prevents operator from applying defaults
    
    Example CORRECT configuration (PITR-compatible):
    
    backup:
      enabled: true
      pitr:
        enabled: true
        storageName: minio-backup
        timeBetweenUploads: 60
      storages:
        minio-backup:
          type: s3
          s3:
            bucket: percona-backups
      schedule:
        - name: "daily-backup"
          schedule: "0 2 * * *"
          storageName: minio-backup
          # NO retention keys - managed by storage lifecycle
    
    Example INCORRECT configuration (breaks PITR):
    
    backup:
      pitr:
        enabled: true
      schedule:
        - name: "daily-backup"
          schedule: "0 2 * * *"
          retention:              # <-- INCOMPATIBLE WITH PITR
            type: "count"
            count: 7
            deleteFromStorage: true
    """
    values, path = get_values_for_test()
    
    backup = values.get('backup', {})
    
    # Check if PITR is enabled
    pitr = backup.get('pitr', {})
    pitr_enabled = pitr.get('enabled', False)
    
    log_check(
        criterion="PITR enabled status",
        expected="checking if PITR is enabled",
        actual=f"pitr.enabled={pitr_enabled}",
        source=path
    )
    
    if not pitr_enabled:
        pytest.skip("PITR is not enabled - retention policy checks not applicable")
    
    # Get all scheduled backups
    schedules = backup.get('schedule', [])
    
    log_check(
        criterion="Backup schedules present",
        expected="at least one schedule",
        actual=f"{len(schedules)} schedule(s)",
        source=path
    )
    
    if len(schedules) == 0:
        pytest.skip("No backup schedules configured")
    
    # Check each schedule for incompatible retention settings
    incompatible_keys = ['keep', 'retention']
    
    for schedule in schedules:
        schedule_name = schedule.get('name', 'unknown')
        
        log_check(
            criterion=f"Schedule '{schedule_name}' must not have retention settings when PITR enabled",
            expected="no retention keys present",
            actual=f"keys={list(schedule.keys())}",
            source=path
        )
        
        # Check for 'keep' field (deprecated but still incompatible)
        if 'keep' in schedule:
            pytest.fail(
                f"Schedule '{schedule_name}' has 'keep' field which is incompatible with PITR. "
                "Remove this field - retention should be managed by storage lifecycle policies."
            )
        
        # Check for 'retention' object
        if 'retention' in schedule:
            retention = schedule['retention']
            
            # Check for specific retention subfields
            retention_subfields = ['type', 'count', 'deleteFromStorage']
            found_subfields = [key for key in retention_subfields if key in retention]
            
            if found_subfields:
                pytest.fail(
                    f"Schedule '{schedule_name}' has retention.{found_subfields} which is incompatible with PITR. "
                    f"Per Percona documentation: 'Disable the retention policy as it is incompatible with point-in-time recovery.' "
                    f"Remove retention configuration from this schedule - use storage lifecycle policies instead."
                )
            
            # If retention exists but has no subfields, it's an empty object - also not ideal
            if not retention:
                pytest.fail(
                    f"Schedule '{schedule_name}' has empty 'retention' object. "
                    "Remove the entire retention key when PITR is enabled."
                )
    
    # If we get here, all schedules are PITR-compatible
    log_check(
        criterion="All backup schedules are PITR-compatible",
        expected="no retention policies configured",
        actual=f"validated {len(schedules)} schedule(s)",
        source=path
    )

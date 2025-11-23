"""
Unit tests for Percona configuration from Fleet.
These tests validate the Fleet-rendered configuration before it's applied to ensure integration tests will pass.
"""
import yaml
import os
import pytest
from conftest import log_check, STORAGE_CLASS_NAME, get_values_for_test


@pytest.mark.unit
def test_percona_values_template_valid_yaml():
    """Test that percona-values.yaml is valid YAML."""
    values, path = get_values_for_test()
    log_check("percona-values.yaml should parse to valid YAML", "not None", f"is None={values is None}", source=path)
    assert values is not None


@pytest.mark.unit
def test_percona_values_pxc_configuration():
    """Test PXC configuration matches expected values."""
    values, path = get_values_for_test()
    
    pxc = values['pxc']
    log_check("pxc.size must be 3 after substitution", "3", f"{pxc['size']}", source=path); assert pxc['size'] == 3
    log_check("pxc.requests.memory should be 4G", "4G", f"{pxc['resources']['requests']['memory']}", source=path); assert pxc['resources']['requests']['memory'] == '4G'
    log_check("pxc.requests.cpu should be 1000m", "1000m", f"{pxc['resources']['requests']['cpu']}", source=path); assert pxc['resources']['requests']['cpu'] == '1000m'
    log_check("pxc.limits.memory should be 6G", "6G", f"{pxc['resources']['limits']['memory']}", source=path); assert pxc['resources']['limits']['memory'] == '6G'
    log_check("pxc.limits.cpu should be 1", "1", f"{pxc['resources']['limits']['cpu']}", source=path); assert pxc['resources']['limits']['cpu'] == 1
    
    # Storage configuration - on-prem uses volumeSpec (raw Kubernetes format)
    pvc_spec = pxc['volumeSpec']['persistentVolumeClaim']
    
    # Check access modes (critical for data integrity)
    access_modes = pvc_spec.get('accessModes', [])
    log_check("pxc.volumeSpec accessModes should include ReadWriteOnce", "ReadWriteOnce in list", f"{access_modes}", source=path)
    assert 'ReadWriteOnce' in access_modes, "PXC must use ReadWriteOnce access mode to prevent data corruption"
    
    # Check storage size
    storage_size = pvc_spec['resources']['requests']['storage']
    log_check("pxc.volumeSpec storage size should be 20Gi", "20Gi", f"{storage_size}", source=path)
    assert storage_size == '20Gi'
    
    # Check storage class
    expected_sc = STORAGE_CLASS_NAME
    storage_class = pvc_spec.get('storageClassName', '')
    log_check("pxc.volumeSpec storageClassName should match expected", f"{expected_sc}", f"{storage_class}", source=path)
    assert storage_class == expected_sc
    log_check("pxc.pdb.maxUnavailable should be 1", "1", f"{pxc['podDisruptionBudget']['maxUnavailable']}", source=path); assert pxc['podDisruptionBudget']['maxUnavailable'] == 1
    
    # Check anti-affinity (on-prem uses antiAffinityTopologyKey)
    affinity = pxc['affinity']
    if 'antiAffinityTopologyKey' in affinity:
        topology_key = affinity['antiAffinityTopologyKey']
        log_check("PXC anti-affinity topologyKey should be kubernetes.io/hostname", "kubernetes.io/hostname", f"{topology_key}", source=path)
        assert topology_key == 'kubernetes.io/hostname', f"Expected kubernetes.io/hostname, got {topology_key}"
    elif 'podAntiAffinity' in affinity:
        pod_anti_affinity = affinity['podAntiAffinity']
        required = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
        log_check("PXC anti-affinity topologyKey should be topology.kubernetes.io/zone", "topology.kubernetes.io/zone", f"{required['topologyKey']}", source=path); assert required['topologyKey'] == 'topology.kubernetes.io/zone'
        label_selector = required['labelSelector']
        match_expr = label_selector['matchExpressions'][0]
        log_check("PXC anti-affinity selector key", "app.kubernetes.io/component", f"{match_expr['key']}", source=path); assert match_expr['key'] == 'app.kubernetes.io/component'
        log_check("PXC anti-affinity selector operator", "In", f"{match_expr['operator']}", source=path); assert match_expr['operator'] == 'In'
        log_check("PXC anti-affinity selector values", "['pxc']", f"{match_expr['values']}", source=path); assert match_expr['values'] == ['pxc']
    else:
        assert False, "PXC must have anti-affinity configured (antiAffinityTopologyKey or podAntiAffinity)"


@pytest.mark.unit
def test_percona_values_haproxy_enabled():
    """Test that HAProxy is enabled (on-prem uses HAProxy, not ProxySQL)."""
    values, path = get_values_for_test()
    log_check("haproxy.enabled should be true", "True", f"{values['haproxy']['enabled']}", source=path)
    assert values['haproxy']['enabled'] is True, "On-prem should use HAProxy for load balancing"


@pytest.mark.unit
def test_percona_values_backup_configuration():
    """Test backup configuration matches expected values."""
    values, path = get_values_for_test()
    
    backup = values['backup']
    # Note: Percona operator doesn't have backup.enabled field - backups are configured via storages and schedules
    
    # Complete backup strategy requires BOTH PITR and scheduled backups
    log_check("backup.pitr.enabled should be true", "True", f"{backup['pitr']['enabled']}", source=path)
    assert backup['pitr']['enabled'] is True, \
        "PITR must be enabled for continuous backup and point-in-time recovery"
    
    schedules = backup.get('schedule', [])
    log_check("backup.schedule must have entries", "> 0", f"{len(schedules)}", source=path)
    assert len(schedules) > 0, \
        "Scheduled backups are required for proper DR - PITR needs base backups to restore from"
    
    # Check PITR details
    log_check("backup.pitr.storageName", "minio", f"{backup['pitr']['storageName']}", source=path); assert backup['pitr']['storageName'] == 'minio'
    log_check("backup.pitr.timeBetweenUploads", "60", f"{backup['pitr']['timeBetweenUploads']}", source=path); assert backup['pitr']['timeBetweenUploads'] == 60
    
    # Check storage configuration
    storage = backup['storages']['minio']
    log_check("backup.storages.minio.type", "s3", f"{storage['type']}", source=path); assert storage['type'] == 's3'
    log_check("s3.bucket", "pxc-backups", f"{storage['s3']['bucket']}", source=path); assert storage['s3']['bucket'] == 'pxc-backups'
    log_check("s3.region", "us-east-1", f"{storage['s3']['region']}", source=path); assert storage['s3']['region'] == 'us-east-1'
    log_check("s3.endpointUrl", "http://minio.minio.svc.cluster.local:9000", f"{storage['s3']['endpointUrl']}", source=path); assert storage['s3']['endpointUrl'] == 'http://minio.minio.svc.cluster.local:9000'
    log_check("s3.forcePathStyle", "True", f"{storage['s3']['forcePathStyle']}", source=path); assert storage['s3']['forcePathStyle'] is True
    log_check("s3.credentialsSecret", "percona-backup-minio-credentials", f"{storage['s3']['credentialsSecret']}", source=path); assert storage['s3']['credentialsSecret'] == 'percona-backup-minio-credentials'
    
    # Check backup schedules (now verified as > 0 above)
    log_check("backup.schedule length", "3", f"{len(schedules)}", source=path); assert len(schedules) == 3
    
    # Daily backup
    daily = next(s for s in schedules if s['name'] == 'daily-backup')
    log_check("daily.schedule", "0 2 * * *", f"{daily['schedule']}", source=path); assert daily['schedule'] == '0 2 * * *'
    log_check("daily.retention.type", "count", f"{daily['retention']['type']}", source=path); assert daily['retention']['type'] == 'count'
    log_check("daily.retention.count", "7", f"{daily['retention']['count']}", source=path); assert daily['retention']['count'] == 7
    log_check("daily.retention.deleteFromStorage", "True", f"{daily['retention']['deleteFromStorage']}", source=path); assert daily['retention']['deleteFromStorage'] is True
    log_check("daily.storageName", "minio", f"{daily['storageName']}", source=path); assert daily['storageName'] == 'minio'
    
    # Weekly backup
    weekly = next(s for s in schedules if s['name'] == 'weekly-backup')
    log_check("weekly.schedule", "0 1 * * 0", f"{weekly['schedule']}", source=path); assert weekly['schedule'] == '0 1 * * 0'
    log_check("weekly.retention.type", "count", f"{weekly['retention']['type']}", source=path); assert weekly['retention']['type'] == 'count'
    log_check("weekly.retention.count", "8", f"{weekly['retention']['count']}", source=path); assert weekly['retention']['count'] == 8
    log_check("weekly.retention.deleteFromStorage", "True", f"{weekly['retention']['deleteFromStorage']}", source=path); assert weekly['retention']['deleteFromStorage'] is True
    log_check("weekly.storageName", "minio", f"{weekly['storageName']}", source=path); assert weekly['storageName'] == 'minio'
    
    # Monthly backup
    monthly = next(s for s in schedules if s['name'] == 'monthly-backup')
    log_check("monthly.schedule", "30 1 1 * *", f"{monthly['schedule']}", source=path); assert monthly['schedule'] == '30 1 1 * *'
    log_check("monthly.retention.type", "count", f"{monthly['retention']['type']}", source=path); assert monthly['retention']['type'] == 'count'
    log_check("monthly.retention.count", "12", f"{monthly['retention']['count']}", source=path); assert monthly['retention']['count'] == 12
    log_check("monthly.retention.deleteFromStorage", "True", f"{monthly['retention']['deleteFromStorage']}", source=path); assert monthly['retention']['deleteFromStorage'] is True
    log_check("monthly.storageName", "minio", f"{monthly['storageName']}", source=path); assert monthly['storageName'] == 'minio'


@pytest.mark.unit
def test_percona_values_template_has_nodes_placeholder():
    """Test that Fleet configuration is valid (placeholder test not applicable for Fleet)."""
    # This test checks template placeholders which don't exist in Fleet-rendered manifests
    # Fleet renders the actual values, so we just verify the configuration is valid
    values, path = get_values_for_test()
    assert values is not None, "Fleet configuration should be valid"


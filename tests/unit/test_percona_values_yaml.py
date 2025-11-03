"""
Unit tests for Percona Helm values template.
These tests validate the configuration before it's applied to ensure integration tests will pass.
"""
import yaml
import os
import pytest


@pytest.mark.unit
def test_percona_values_template_valid_yaml():
    """Test that percona-values.yaml is valid YAML."""
    path = os.path.join(os.getcwd(), 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Replace placeholder with test value to make valid YAML
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    assert values is not None


@pytest.mark.unit
def test_percona_values_pxc_configuration():
    """Test PXC configuration matches expected values."""
    path = os.path.join(os.getcwd(), 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Replace placeholder with test value
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    pxc = values['pxc']
    assert pxc['size'] == 3
    assert pxc['resources']['requests']['memory'] == '1Gi'
    assert pxc['resources']['requests']['cpu'] == '500m'
    assert pxc['resources']['limits']['memory'] == '2Gi'
    assert pxc['resources']['limits']['cpu'] == 1
    assert pxc['persistence']['enabled'] is True
    assert pxc['persistence']['size'] == '20Gi'
    assert pxc['persistence']['accessMode'] == 'ReadWriteOnce'
    assert pxc['persistence']['storageClass'] == 'gp3'
    assert pxc['podDisruptionBudget']['maxUnavailable'] == 1
    
    # Check anti-affinity
    affinity = pxc['affinity']['podAntiAffinity']
    required = affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
    assert required['topologyKey'] == 'topology.kubernetes.io/zone'
    label_selector = required['labelSelector']
    match_expr = label_selector['matchExpressions'][0]
    assert match_expr['key'] == 'app.kubernetes.io/component'
    assert match_expr['operator'] == 'In'
    assert match_expr['values'] == ['pxc']


@pytest.mark.unit
def test_percona_values_proxysql_configuration():
    """Test ProxySQL configuration matches expected values."""
    path = os.path.join(os.getcwd(), 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    proxysql = values['proxysql']
    assert proxysql['enabled'] is True
    assert proxysql['size'] == 3
    assert proxysql['image'] == 'percona/proxysql2:2.7.3'
    assert proxysql['resources']['requests']['memory'] == '256Mi'
    assert proxysql['resources']['requests']['cpu'] == '100m'
    assert proxysql['resources']['limits']['memory'] == '512Mi'
    assert proxysql['resources']['limits']['cpu'] == '500m'
    assert proxysql['podDisruptionBudget']['maxUnavailable'] == 1
    
    # Check anti-affinity
    affinity = proxysql['affinity']['podAntiAffinity']
    required = affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
    assert required['topologyKey'] == 'topology.kubernetes.io/zone'
    label_selector = required['labelSelector']
    match_expr = label_selector['matchExpressions'][0]
    assert match_expr['key'] == 'app.kubernetes.io/component'
    assert match_expr['operator'] == 'In'
    assert match_expr['values'] == ['proxysql']
    
    # Check volume spec
    volume_spec = proxysql['volumeSpec']['persistentVolumeClaim']
    assert volume_spec['accessModes'] == ['ReadWriteOnce']
    assert volume_spec['resources']['requests']['storage'] == '5Gi'
    assert volume_spec['storageClassName'] == 'gp3'


@pytest.mark.unit
def test_percona_values_haproxy_disabled():
    """Test that HAProxy is disabled."""
    path = os.path.join(os.getcwd(), 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    assert values['haproxy']['enabled'] is False


@pytest.mark.unit
def test_percona_values_backup_configuration():
    """Test backup configuration matches expected values."""
    path = os.path.join(os.getcwd(), 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    backup = values['backup']
    assert backup['enabled'] is True
    assert backup['pitr']['enabled'] is True
    assert backup['pitr']['storageName'] == 'minio-backup'
    assert backup['pitr']['timeBetweenUploads'] == 60
    
    # Check storage configuration
    storage = backup['storages']['minio-backup']
    assert storage['type'] == 's3'
    assert storage['s3']['bucket'] == 'percona-backups'
    assert storage['s3']['region'] == 'us-east-1'
    assert storage['s3']['endpointUrl'] == 'http://minio.minio.svc.cluster.local:9000'
    assert storage['s3']['forcePathStyle'] is True
    assert storage['s3']['credentialsSecret'] == 'percona-backup-minio-credentials'
    
    # Check backup schedules
    schedules = backup['schedule']
    assert len(schedules) == 3
    
    # Daily backup
    daily = next(s for s in schedules if s['name'] == 'daily-backup')
    assert daily['schedule'] == '0 2 * * *'
    assert daily['retention']['type'] == 'count'
    assert daily['retention']['count'] == 7
    assert daily['retention']['deleteFromStorage'] is True
    assert daily['storageName'] == 'minio-backup'
    
    # Weekly backup
    weekly = next(s for s in schedules if s['name'] == 'weekly-backup')
    assert weekly['schedule'] == '0 1 * * 0'
    assert weekly['retention']['type'] == 'count'
    assert weekly['retention']['count'] == 8
    assert weekly['retention']['deleteFromStorage'] is True
    assert weekly['storageName'] == 'minio-backup'
    
    # Monthly backup
    monthly = next(s for s in schedules if s['name'] == 'monthly-backup')
    assert monthly['schedule'] == '30 1 1 * *'
    assert monthly['retention']['type'] == 'count'
    assert monthly['retention']['count'] == 12
    assert monthly['retention']['deleteFromStorage'] is True
    assert monthly['storageName'] == 'minio-backup'


@pytest.mark.unit
def test_percona_values_template_has_nodes_placeholder():
    """Test that template contains NODES placeholder for substitution."""
    path = os.path.join(os.getcwd(), 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    assert '{{NODES}}' in content


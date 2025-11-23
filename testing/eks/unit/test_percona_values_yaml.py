"""
Unit tests for Percona Helm values template.
These tests validate the configuration before it's applied to ensure integration tests will pass.
"""
import yaml
import os
import pytest
from conftest import log_check, ON_PREM, STORAGE_CLASS_NAME


@pytest.mark.unit
def test_percona_values_template_valid_yaml():
    """Test that percona-values.yaml is valid YAML."""
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Replace placeholder with test value to make valid YAML
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    log_check("percona-values.yaml should parse to valid YAML", "not None", f"is None={values is None}", source=path)
    assert values is not None


@pytest.mark.unit
def test_percona_values_pxc_configuration():
    """Test PXC configuration matches expected values."""
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Replace placeholder with test value
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    pxc = values['pxc']
    log_check("pxc.size must be 3 after substitution", "3", f"{pxc['size']}", source=path); assert pxc['size'] == 3
    log_check("pxc.requests.memory should be 1Gi", "1Gi", f"{pxc['resources']['requests']['memory']}", source=path); assert pxc['resources']['requests']['memory'] == '1Gi'
    log_check("pxc.requests.cpu should be 500m", "500m", f"{pxc['resources']['requests']['cpu']}", source=path); assert pxc['resources']['requests']['cpu'] == '500m'
    log_check("pxc.limits.memory should be 2Gi", "2Gi", f"{pxc['resources']['limits']['memory']}", source=path); assert pxc['resources']['limits']['memory'] == '2Gi'
    log_check("pxc.limits.cpu should be 1", "1", f"{pxc['resources']['limits']['cpu']}", source=path); assert pxc['resources']['limits']['cpu'] == 1
    log_check("pxc.persistence.enabled should be true", "True", f"{pxc['persistence']['enabled']}", source=path); assert pxc['persistence']['enabled'] is True
    log_check("pxc.persistence.size should be 10Gi", "10Gi", f"{pxc['persistence']['size']}", source=path); assert pxc['persistence']['size'] == '10Gi'
    log_check("pxc.persistence.accessMode should be ReadWriteOnce", "ReadWriteOnce", f"{pxc['persistence']['accessMode']}", source=path); assert pxc['persistence']['accessMode'] == 'ReadWriteOnce'
    expected_sc = STORAGE_CLASS_NAME if ON_PREM else 'gp3'
    log_check("pxc.persistence.storageClass should match expected", f"{expected_sc}", f"{pxc['persistence']['storageClass']}", source=path); assert pxc['persistence']['storageClass'] == expected_sc
    log_check("pxc.pdb.maxUnavailable should be 1", "1", f"{pxc['podDisruptionBudget']['maxUnavailable']}", source=path); assert pxc['podDisruptionBudget']['maxUnavailable'] == 1
    
    # Check anti-affinity
    affinity = pxc['affinity']['podAntiAffinity']
    required = affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
    log_check("PXC anti-affinity topologyKey should be topology.kubernetes.io/zone", "topology.kubernetes.io/zone", f"{required['topologyKey']}", source=path); assert required['topologyKey'] == 'topology.kubernetes.io/zone'
    label_selector = required['labelSelector']
    match_expr = label_selector['matchExpressions'][0]
    log_check("PXC anti-affinity selector key", "app.kubernetes.io/component", f"{match_expr['key']}", source=path); assert match_expr['key'] == 'app.kubernetes.io/component'
    log_check("PXC anti-affinity selector operator", "In", f"{match_expr['operator']}", source=path); assert match_expr['operator'] == 'In'
    log_check("PXC anti-affinity selector values", "['pxc']", f"{match_expr['values']}", source=path); assert match_expr['values'] == ['pxc']


@pytest.mark.unit
def test_percona_values_proxysql_configuration(request):
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests run only with --proxysql")
    """Test ProxySQL configuration matches expected values."""
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    proxysql = values['proxysql']
    log_check("proxysql.enabled should be true", "True", f"{proxysql['enabled']}", source=path); assert proxysql['enabled'] is True
    log_check("proxysql.size should be 3", "3", f"{proxysql['size']}", source=path); assert proxysql['size'] == 3
    log_check("proxysql.image matches expected", "percona/proxysql2:2.7.3", f"{proxysql['image']}", source=path); assert proxysql['image'] == 'percona/proxysql2:2.7.3'
    log_check("proxysql.requests.memory", "256Mi", f"{proxysql['resources']['requests']['memory']}", source=path); assert proxysql['resources']['requests']['memory'] == '256Mi'
    log_check("proxysql.requests.cpu", "100m", f"{proxysql['resources']['requests']['cpu']}", source=path); assert proxysql['resources']['requests']['cpu'] == '100m'
    log_check("proxysql.limits.memory", "512Mi", f"{proxysql['resources']['limits']['memory']}", source=path); assert proxysql['resources']['limits']['memory'] == '512Mi'
    log_check("proxysql.limits.cpu", "500m", f"{proxysql['resources']['limits']['cpu']}", source=path); assert proxysql['resources']['limits']['cpu'] == '500m'
    log_check("proxysql.pdb.maxUnavailable", "1", f"{proxysql['podDisruptionBudget']['maxUnavailable']}", source=path); assert proxysql['podDisruptionBudget']['maxUnavailable'] == 1
    
    # Check anti-affinity
    affinity = proxysql['affinity']['podAntiAffinity']
    required = affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
    log_check("ProxySQL anti-affinity topologyKey", "topology.kubernetes.io/zone", f"{required['topologyKey']}", source=path); assert required['topologyKey'] == 'topology.kubernetes.io/zone'
    label_selector = required['labelSelector']
    match_expr = label_selector['matchExpressions'][0]
    log_check("ProxySQL anti-affinity selector key", "app.kubernetes.io/component", f"{match_expr['key']}", source=path); assert match_expr['key'] == 'app.kubernetes.io/component'
    log_check("ProxySQL anti-affinity selector operator", "In", f"{match_expr['operator']}", source=path); assert match_expr['operator'] == 'In'
    log_check("ProxySQL anti-affinity selector values", "['proxysql']", f"{match_expr['values']}", source=path); assert match_expr['values'] == ['proxysql']
    
    # Check volume spec
    volume_spec = proxysql['volumeSpec']['persistentVolumeClaim']
    log_check("ProxySQL PVC accessModes", "['ReadWriteOnce']", f"{volume_spec['accessModes']}", source=path); assert volume_spec['accessModes'] == ['ReadWriteOnce']
    log_check("ProxySQL PVC requests.storage", "5Gi", f"{volume_spec['resources']['requests']['storage']}", source=path); assert volume_spec['resources']['requests']['storage'] == '5Gi'
    expected_sc = STORAGE_CLASS_NAME if ON_PREM else 'gp3'
    log_check("ProxySQL PVC storageClassName", f"{expected_sc}", f"{volume_spec['storageClassName']}", source=path); assert volume_spec['storageClassName'] == expected_sc


@pytest.mark.unit
def test_percona_values_haproxy_disabled(request):
    if not request.config.getoption('--proxysql'):
        pytest.skip("This HAProxy-disabled test is only relevant when ProxySQL is enabled")
    """Test that HAProxy is disabled."""
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    log_check("haproxy.enabled should be false", "False", f"{values['haproxy']['enabled']}", source=path); assert values['haproxy']['enabled'] is False


@pytest.mark.unit
def test_percona_values_backup_configuration():
    """Test backup configuration matches expected values."""
    from conftest import TEST_NAMESPACE
    
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    backup = values['backup']
    log_check("backup.enabled should be true", "True", f"{backup['enabled']}", source=path); assert backup['enabled'] is True
    log_check("backup.pitr.enabled should be true", "True", f"{backup['pitr']['enabled']}", source=path); assert backup['pitr']['enabled'] is True
    log_check("backup.pitr.storageName", "minio-backup", f"{backup['pitr']['storageName']}", source=path); assert backup['pitr']['storageName'] == 'minio-backup'
    log_check("backup.pitr.timeBetweenUploads", "60", f"{backup['pitr']['timeBetweenUploads']}", source=path); assert backup['pitr']['timeBetweenUploads'] == 60
    
    # Check storage configuration
    storage = backup['storages']['minio-backup']
    log_check("backup.storages.minio-backup.type", "s3", f"{storage['type']}", source=path); assert storage['type'] == 's3'
    
    # Bucket name should be pxc-{namespace}
    expected_bucket = f"pxc-{TEST_NAMESPACE}"
    actual_bucket = storage['s3']['bucket']
    log_check("s3.bucket", expected_bucket, f"{actual_bucket}", source=path)
    assert actual_bucket == expected_bucket, \
        f"S3 bucket must be named 'pxc-{{namespace}}'. Expected: {expected_bucket}, got: {actual_bucket}"
    
    log_check("s3.region", "us-east-1", f"{storage['s3']['region']}", source=path); assert storage['s3']['region'] == 'us-east-1'
    log_check("s3.endpointUrl", "http://minio.minio.svc.cluster.local:9000", f"{storage['s3']['endpointUrl']}", source=path); assert storage['s3']['endpointUrl'] == 'http://minio.minio.svc.cluster.local:9000'
    log_check("s3.forcePathStyle", "True", f"{storage['s3']['forcePathStyle']}", source=path); assert storage['s3']['forcePathStyle'] is True
    log_check("s3.credentialsSecret", "initial-cluster-secrets", f"{storage['s3']['credentialsSecret']}", source=path); assert storage['s3']['credentialsSecret'] == 'initial-cluster-secrets'
    
    # Check backup schedules - require at least one
    schedules = backup['schedule']
    log_check("backup.schedule must have at least one entry", ">= 1", f"{len(schedules)}", source=path)
    assert len(schedules) >= 1, "At least one scheduled backup is required for proper DR"


@pytest.mark.unit
def test_percona_values_template_has_nodes_placeholder():
    """Test that template contains NODES placeholder for substitution."""
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    log_check("Template should contain {{NODES}} placeholder", "present=True", f"present={{'{{NODES}}' in content}}", source=path)
    assert '{{NODES}}' in content


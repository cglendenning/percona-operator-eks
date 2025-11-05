"""
Unit tests for storage class configuration.
Validates Percona best practices for storage configuration.
"""
import os
import yaml
import pytest
from tests.conftest import log_check, ON_PREM, STORAGE_CLASS_NAME


@pytest.mark.unit
def test_storage_class_yaml_valid():
    """Test that storage class YAML is valid."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        sc = yaml.safe_load(content)
    
    expected_name = 'gp3' if not ON_PREM else STORAGE_CLASS_NAME
    log_check(
        criterion=f"StorageClass YAML should define kind=StorageClass and name={expected_name}",
        expected=f"kind=StorageClass, name={expected_name}",
        actual=f"kind={sc.get('kind')}, name={sc.get('metadata',{}).get('name')}",
        source=path,
    )
    assert sc is not None
    assert sc['kind'] == 'StorageClass'
    assert sc['metadata']['name'] == expected_name


@pytest.mark.unit
def test_storage_class_gp3_configuration():
    """Test storage class configuration matches Percona best practices."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    # GP3 on EKS; on-prem may differ (skip provisioner/type strictness)
    expected_name = 'gp3' if not ON_PREM else STORAGE_CLASS_NAME
    log_check("StorageClass name", expected_name, f"name={sc['metadata']['name']}", source=path)
    assert sc['metadata']['name'] == expected_name
    if not ON_PREM:
        log_check("Provisioner must be ebs.csi.aws.com", "ebs.csi.aws.com", f"{sc['provisioner']}", source=path)
        assert sc['provisioner'] == 'ebs.csi.aws.com'
        log_check("parameters.type must be gp3", "gp3", f"{sc['parameters']['type']}", source=path)
        assert sc['parameters']['type'] == 'gp3'
    log_check("parameters.fsType must be xfs", "xfs", f"{sc['parameters']['fsType']}", source=path)
    assert sc['parameters']['fsType'] == 'xfs', "XFS is recommended for Percona"
    log_check("parameters.encrypted must be 'true'", "'true'", f"{sc['parameters']['encrypted']}", source=path)
    assert sc['parameters']['encrypted'] == 'true', "Encryption at rest is required"
    log_check("allowVolumeExpansion must be True", "True", f"{sc['allowVolumeExpansion']}", source=path)
    assert sc['allowVolumeExpansion'] is True, "Volume expansion must be enabled"
    log_check("volumeBindingMode must be WaitForFirstConsumer", "WaitForFirstConsumer", f"{sc['volumeBindingMode']}", source=path)
    assert sc['volumeBindingMode'] == 'WaitForFirstConsumer', "WaitForFirstConsumer improves multi-AZ placement"


@pytest.mark.unit
def test_storage_class_default_annotation():
    """Test that gp3 is set as default storage class."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    annotation = sc['metadata']['annotations']['storageclass.kubernetes.io/is-default-class']
    if not ON_PREM:
        log_check("gp3 should be default StorageClass annotation", "true", f"{annotation}", source=path)
        assert annotation == 'true', "gp3 should be the default storage class"


@pytest.mark.unit
def test_storage_class_reclaim_policy():
    """Test that reclaim policy is appropriate."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    # Delete is appropriate for development/test, Retain may be preferred for production
    # But Delete is acceptable and matches the template
    log_check("reclaimPolicy should be Delete or Retain", "in ['Delete','Retain']", f"{sc['reclaimPolicy']}", source=path)
    assert sc['reclaimPolicy'] in ['Delete', 'Retain']


@pytest.mark.unit
def test_percona_values_uses_gp3_storage_class():
    """Test that Percona values template uses gp3 storage class."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # PXC should use gp3
    log_check("PXC storageClass must be gp3", "gp3", f"{values['pxc']['persistence']['storageClass']}", source=path)
    assert values['pxc']['persistence']['storageClass'] == 'gp3'
    
    # ProxySQL should use gp3
    log_check(
        "ProxySQL PVC storageClassName must be gp3",
        "gp3",
        f"{values['proxysql']['volumeSpec']['persistentVolumeClaim']['storageClassName']}",
        source=path,
    )
    assert values['proxysql']['volumeSpec']['persistentVolumeClaim']['storageClassName'] == 'gp3'


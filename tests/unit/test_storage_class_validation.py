"""
Unit tests for storage class configuration.
Validates Percona best practices for storage configuration.
"""
import os
import yaml
import pytest


@pytest.mark.unit
def test_storage_class_yaml_valid():
    """Test that storage class YAML is valid."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        sc = yaml.safe_load(content)
    
    assert sc is not None
    assert sc['kind'] == 'StorageClass'
    assert sc['metadata']['name'] == 'gp3'


@pytest.mark.unit
def test_storage_class_gp3_configuration():
    """Test storage class configuration matches Percona best practices."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    # GP3 is preferred for better performance/cost ratio
    assert sc['metadata']['name'] == 'gp3'
    assert sc['provisioner'] == 'ebs.csi.aws.com'
    assert sc['parameters']['type'] == 'gp3'
    assert sc['parameters']['fsType'] == 'xfs', "XFS is recommended for Percona"
    assert sc['parameters']['encrypted'] == 'true', "Encryption at rest is required"
    assert sc['allowVolumeExpansion'] is True, "Volume expansion must be enabled"
    assert sc['volumeBindingMode'] == 'WaitForFirstConsumer', "WaitForFirstConsumer improves multi-AZ placement"


@pytest.mark.unit
def test_storage_class_default_annotation():
    """Test that gp3 is set as default storage class."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    annotation = sc['metadata']['annotations']['storageclass.kubernetes.io/is-default-class']
    assert annotation == 'true', "gp3 should be the default storage class"


@pytest.mark.unit
def test_storage_class_reclaim_policy():
    """Test that reclaim policy is appropriate."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    # Delete is appropriate for development/test, Retain may be preferred for production
    # But Delete is acceptable and matches the template
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
    assert values['pxc']['persistence']['storageClass'] == 'gp3'
    
    # ProxySQL should use gp3
    assert values['proxysql']['volumeSpec']['persistentVolumeClaim']['storageClassName'] == 'gp3'


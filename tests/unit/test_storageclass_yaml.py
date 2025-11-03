import yaml
import os
import pytest


@pytest.mark.unit
def test_storageclass_gp3_template_valid():
    path = os.path.join(os.getcwd(), 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)

    assert sc['apiVersion'] == 'storage.k8s.io/v1'
    assert sc['kind'] == 'StorageClass'
    assert sc['metadata']['name'] == 'gp3'
    assert sc['provisioner'] in ['kubernetes.io/aws-ebs', 'ebs.csi.aws.com']
    assert sc['parameters']['type'] == 'gp3'
    assert sc['allowVolumeExpansion'] is True
    assert sc['reclaimPolicy'] in ['Delete', 'Retain']
    assert sc['volumeBindingMode'] in ['WaitForFirstConsumer', 'Immediate']


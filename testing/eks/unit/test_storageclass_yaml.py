import yaml
import os
import pytest
from conftest import log_check


@pytest.mark.unit
def test_storageclass_gp3_template_valid():
    path = os.path.join(os.getcwd(), '..', '..', 'percona', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)

    log_check("apiVersion", "storage.k8s.io/v1", f"{sc['apiVersion']}", source=path); assert sc['apiVersion'] == 'storage.k8s.io/v1'
    log_check("kind", "StorageClass", f"{sc['kind']}", source=path); assert sc['kind'] == 'StorageClass'
    log_check("name", "gp3", f"{sc['metadata']['name']}", source=path); assert sc['metadata']['name'] == 'gp3'
    log_check("provisioner", "aws-ebs csi", f"{sc['provisioner']}", source=path); assert sc['provisioner'] in ['kubernetes.io/aws-ebs', 'ebs.csi.aws.com']
    log_check("parameters.type", "gp3", f"{sc['parameters']['type']}", source=path); assert sc['parameters']['type'] == 'gp3'
    log_check("allowVolumeExpansion", "True", f"{sc['allowVolumeExpansion']}", source=path); assert sc['allowVolumeExpansion'] is True
    log_check("reclaimPolicy", "Delete/Retain", f"{sc['reclaimPolicy']}", source=path); assert sc['reclaimPolicy'] in ['Delete', 'Retain']
    log_check("volumeBindingMode", "WaitForFirstConsumer/Immediate", f"{sc['volumeBindingMode']}", source=path); assert sc['volumeBindingMode'] in ['WaitForFirstConsumer', 'Immediate']


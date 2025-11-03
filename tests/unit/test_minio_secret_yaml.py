import yaml
import os
import pytest


@pytest.mark.unit
def test_minio_credentials_secret_template_valid():
    path = os.path.join(os.getcwd(), 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Check placeholders exist in template
        assert '{{NAMESPACE}}' in content
        assert '{{AWS_ACCESS_KEY_ID}}' in content
        assert '{{AWS_SECRET_ACCESS_KEY}}' in content
        
        # Replace placeholders with test values to validate structure
        content = content.replace('{{NAMESPACE}}', 'test-namespace')
        content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'test-access-key')
        content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test-secret-key')
        doc = yaml.safe_load(content)

    assert doc['apiVersion'] == 'v1'
    assert doc['kind'] == 'Secret'
    assert doc['metadata']['name'] == 'percona-backup-minio-credentials'
    assert doc['metadata']['namespace'] == 'test-namespace'
    assert doc['type'] == 'Opaque'
    sd = doc['stringData']
    assert sd['AWS_ACCESS_KEY_ID'] == 'test-access-key'
    assert sd['AWS_SECRET_ACCESS_KEY'] == 'test-secret-key'
    assert sd['AWS_ENDPOINT'] == 'http://minio.minio.svc.cluster.local:9000'
    assert sd['AWS_DEFAULT_REGION'] == 'us-east-1'


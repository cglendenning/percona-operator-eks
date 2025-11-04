import yaml
import os
import pytest
from tests.conftest import log_check


@pytest.mark.unit
def test_minio_credentials_secret_template_valid():
    path = os.path.join(os.getcwd(), 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Check placeholders exist in template
        log_check("Secret template must include placeholders", "{{NAMESPACE}}, {{AWS_ACCESS_KEY_ID}}, {{AWS_SECRET_ACCESS_KEY}}", f"present={[p for p in ['{{NAMESPACE}}','{{AWS_ACCESS_KEY_ID}}','{{AWS_SECRET_ACCESS_KEY}}'] if p in content]}", source=path)
        assert '{{NAMESPACE}}' in content
        assert '{{AWS_ACCESS_KEY_ID}}' in content
        assert '{{AWS_SECRET_ACCESS_KEY}}' in content
        
        # Replace placeholders with test values to validate structure
        content = content.replace('{{NAMESPACE}}', 'test-namespace')
        content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'test-access-key')
        content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test-secret-key')
        doc = yaml.safe_load(content)

    log_check("apiVersion should be v1", "v1", f"{doc['apiVersion']}", source=path); assert doc['apiVersion'] == 'v1'
    log_check("kind should be Secret", "Secret", f"{doc['kind']}", source=path); assert doc['kind'] == 'Secret'
    log_check("metadata.name", "percona-backup-minio-credentials", f"{doc['metadata']['name']}", source=path); assert doc['metadata']['name'] == 'percona-backup-minio-credentials'
    log_check("metadata.namespace", "test-namespace", f"{doc['metadata']['namespace']}", source=path); assert doc['metadata']['namespace'] == 'test-namespace'
    log_check("type should be Opaque", "Opaque", f"{doc['type']}", source=path); assert doc['type'] == 'Opaque'
    sd = doc['stringData']
    log_check("stringData AWS_ACCESS_KEY_ID", "test-access-key", f"{sd['AWS_ACCESS_KEY_ID']}", source=path); assert sd['AWS_ACCESS_KEY_ID'] == 'test-access-key'
    log_check("stringData AWS_SECRET_ACCESS_KEY", "test-secret-key", f"{sd['AWS_SECRET_ACCESS_KEY']}", source=path); assert sd['AWS_SECRET_ACCESS_KEY'] == 'test-secret-key'
    log_check("stringData AWS_ENDPOINT", "http://minio.minio.svc.cluster.local:9000", f"{sd['AWS_ENDPOINT']}", source=path); assert sd['AWS_ENDPOINT'] == 'http://minio.minio.svc.cluster.local:9000'
    log_check("stringData AWS_DEFAULT_REGION", "us-east-1", f"{sd['AWS_DEFAULT_REGION']}", source=path); assert sd['AWS_DEFAULT_REGION'] == 'us-east-1'


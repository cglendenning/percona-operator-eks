"""
Unit tests for MinIO credentials secret template.
Validates secret structure and placeholder substitution.
"""
import os
import yaml
import pytest
import re


@pytest.mark.unit
def test_minio_secret_yaml_valid():
    """Test that MinIO secret YAML is valid."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Replace placeholders for validation
        content = content.replace('{{NAMESPACE}}', 'test-namespace')
        content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'test-access-key')
        content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test-secret-key')
        secret = yaml.safe_load(content)
    
    assert secret is not None
    assert secret['kind'] == 'Secret'
    assert secret['type'] == 'Opaque'


@pytest.mark.unit
def test_minio_secret_template_placeholders():
    """Test that template contains required placeholders."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    assert '{{NAMESPACE}}' in content
    assert '{{AWS_ACCESS_KEY_ID}}' in content
    assert '{{AWS_SECRET_ACCESS_KEY}}' in content


@pytest.mark.unit
def test_minio_secret_placeholder_substitution():
    """Test that placeholders are correctly substituted."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Substitute placeholders
    content = content.replace('{{NAMESPACE}}', 'percona')
    content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'minioadmin')
    content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'minioadmin123')
    
    secret = yaml.safe_load(content)
    
    assert secret['metadata']['namespace'] == 'percona'
    assert secret['stringData']['AWS_ACCESS_KEY_ID'] == 'minioadmin'
    assert secret['stringData']['AWS_SECRET_ACCESS_KEY'] == 'minioadmin123'
    assert secret['stringData']['AWS_ENDPOINT'] == 'http://minio.minio.svc.cluster.local:9000'
    assert secret['stringData']['AWS_DEFAULT_REGION'] == 'us-east-1'


@pytest.mark.unit
def test_minio_secret_name_matches_percona_config():
    """Test that secret name matches what Percona backup config expects."""
    secret_path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'minio-credentials-secret.yaml')
    values_path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    
    with open(secret_path, 'r', encoding='utf-8') as f:
        secret_content = f.read()
        secret_content = secret_content.replace('{{NAMESPACE}}', 'test')
        secret_content = secret_content.replace('{{AWS_ACCESS_KEY_ID}}', 'test')
        secret_content = secret_content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test')
        secret = yaml.safe_load(secret_content)
    
    with open(values_path, 'r', encoding='utf-8') as f:
        values_content = f.read()
        values_content = values_content.replace('{{NODES}}', '3')
        values = yaml.safe_load(values_content)
    
    secret_name = secret['metadata']['name']
    expected_secret_name = values['backup']['storages']['minio-backup']['s3']['credentialsSecret']
    
    assert secret_name == expected_secret_name, \
        f"Secret name {secret_name} must match backup config {expected_secret_name}"


@pytest.mark.unit
def test_minio_secret_required_fields():
    """Test that secret contains all required fields for S3 backup."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NAMESPACE}}', 'test')
        content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'test-key')
        content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test-secret')
        secret = yaml.safe_load(content)
    
    string_data = secret['stringData']
    
    # Required fields for S3-compatible storage
    assert 'AWS_ACCESS_KEY_ID' in string_data
    assert 'AWS_SECRET_ACCESS_KEY' in string_data
    assert 'AWS_ENDPOINT' in string_data
    assert 'AWS_DEFAULT_REGION' in string_data
    
    # Values should not be empty
    assert string_data['AWS_ACCESS_KEY_ID']
    assert string_data['AWS_SECRET_ACCESS_KEY']
    assert string_data['AWS_ENDPOINT']
    assert string_data['AWS_DEFAULT_REGION']


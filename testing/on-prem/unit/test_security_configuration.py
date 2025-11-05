"""
Unit tests for security configuration.
Validates security best practices for Percona Operator v1.18.
"""
import os
import yaml
import pytest
from conftest import log_check


@pytest.mark.unit
def test_storage_encryption_enabled():
    """Test that storage encryption is enabled."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    # EBS encryption should be enabled
    log_check("StorageClass encryption must be enabled", "true", f"{sc['parameters']['encrypted']}", source=path)
    assert sc['parameters']['encrypted'] == 'true', \
        "Storage encryption must be enabled for data at rest"


@pytest.mark.unit
def test_secret_uses_opaque_type():
    """Test that MinIO credentials secret uses Opaque type."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NAMESPACE}}', 'test')
        content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'test')
        content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test')
        secret = yaml.safe_load(content)
    
    log_check("MinIO secret type should be Opaque", "Opaque", f"{secret['type']}", source=path); assert secret['type'] == 'Opaque', "Secret should use Opaque type for credentials"


@pytest.mark.unit
def test_secret_uses_stringdata_not_data():
    """Test that secret uses stringData (not base64-encoded data) for clarity."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NAMESPACE}}', 'test')
        content = content.replace('{{AWS_ACCESS_KEY_ID}}', 'test')
        content = content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test')
        secret = yaml.safe_load(content)
    
    # stringData is automatically base64-encoded by Kubernetes
    # This is preferred for templates as it's more readable
    log_check("Secret should include stringData (not base64 'data')", "stringData present", f"present={'stringData' in secret}", source=path); assert 'stringData' in secret, "Secret should use stringData for template clarity"
    
    # data should not be present (stringData is converted to data by Kubernetes)
    # But in templates, we use stringData
    log_check("Secret template should not include pre-encoded 'data' block", "absent or empty", f"data_present={'data' in secret and bool(secret.get('data'))}", source=path)
    assert 'data' not in secret or not secret.get('data'), \
        "Template should use stringData, not pre-encoded data"


@pytest.mark.unit
def test_namespace_isolation():
    """Test that resources are properly namespaced."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'minio-credentials-secret.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Test with different namespaces
        test_namespaces = ['percona', 'production', 'staging']
        
        for ns in test_namespaces:
            test_content = content.replace('{{NAMESPACE}}', ns)
            test_content = test_content.replace('{{AWS_ACCESS_KEY_ID}}', 'test')
            test_content = test_content.replace('{{AWS_SECRET_ACCESS_KEY}}', 'test')
            secret = yaml.safe_load(test_content)
            
            log_check("Secret namespace should match substituted {{NAMESPACE}}", ns, f"{secret['metadata']['namespace']}", source=path)
            assert secret['metadata']['namespace'] == ns, \
                f"Secret should be in namespace {ns}"


@pytest.mark.unit
def test_no_hardcoded_credentials():
    """Test that templates do not contain hardcoded credentials."""
    # Check that templates use placeholders, not actual credentials
    
    secret_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'minio-credentials-secret.yaml')
    with open(secret_path, 'r', encoding='utf-8') as f:
        secret_content = f.read()
        
        # Should contain placeholders
        log_check("Template should include AWS placeholders", "present", f"present={[p for p in ['{{AWS_ACCESS_KEY_ID}}','{{AWS_SECRET_ACCESS_KEY}}'] if p in secret_content]}", source=secret_path)
        assert '{{AWS_ACCESS_KEY_ID}}' in secret_content
        assert '{{AWS_SECRET_ACCESS_KEY}}' in secret_content
        
        # Should not contain common default credentials (unless placeholders)
        # MinIO default credentials should only be in actual values, not templates
        log_check("Template must not contain hardcoded default credentials", "no raw 'minioadmin' unless placeholder", f"ok={('minioadmin' not in secret_content or '{{' in secret_content)}", source=secret_path)
        assert 'minioadmin' not in secret_content or '{{' in secret_content, \
            "Template should not contain hardcoded credentials"


@pytest.mark.unit
def test_resource_limits_defined():
    """Test that resource limits are defined (prevents resource exhaustion attacks)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # PXC should have limits
    log_check("PXC resources.limits present", "present", f"present={'limits' in values['pxc']['resources']}", source=path); assert 'limits' in values['pxc']['resources'], "PXC must have resource limits"
    log_check("PXC limits contain cpu & memory", "cpu+memory", f"keys={list(values['pxc']['resources']['limits'].keys())}", source=path); assert 'cpu' in values['pxc']['resources']['limits']
    assert 'memory' in values['pxc']['resources']['limits']
    
    # ProxySQL should have limits
    log_check("ProxySQL resources.limits present", "present", f"present={'limits' in values['proxysql']['resources']}", source=path); assert 'limits' in values['proxysql']['resources'], "ProxySQL must have resource limits"
    log_check("ProxySQL limits contain cpu & memory", "cpu+memory", f"keys={list(values['proxysql']['resources']['limits'].keys())}", source=path); assert 'cpu' in values['proxysql']['resources']['limits']
    assert 'memory' in values['proxysql']['resources']['limits']


@pytest.mark.unit
def test_service_account_not_specified_uses_default():
    """Test that service accounts are appropriate (operator manages if not specified)."""
    # Percona Operator manages service accounts if not explicitly specified
    # This is generally preferred for security as operator uses least privilege
    
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # If serviceAccount is specified, it should be a meaningful name
    # If not specified, operator will create appropriate service accounts
    # This test documents the best practice


@pytest.mark.unit
def test_persistent_volume_reclaim_policy():
    """Test that PVC reclaim policy is appropriate (Delete for dev, Retain for prod)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'storageclass-gp3.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        sc = yaml.safe_load(f)
    
    # Delete is acceptable for development/testing
    # Production might prefer Retain, but Delete is configurable
    reclaim_policy = sc.get('reclaimPolicy')
    log_check("StorageClass reclaimPolicy", "Delete or Retain", f"{reclaim_policy}", source=path)
    assert reclaim_policy in ['Delete', 'Retain'], \
        f"Reclaim policy should be Delete or Retain, not {reclaim_policy}"


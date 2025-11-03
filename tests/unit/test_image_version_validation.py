"""
Unit tests for container image version validation.
Validates that image versions match Percona Operator v1.18 recommendations.
"""
import os
import yaml
import pytest
import re


@pytest.mark.unit
def test_proxysql_image_version():
    """Test that ProxySQL image version is specified and valid."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    proxysql = values['proxysql']
    assert 'image' in proxysql, "ProxySQL image must be specified"
    
    image = proxysql['image']
    # Image format: registry/name:tag
    assert ':' in image, "Image must include version tag"
    
    image_parts = image.split(':')
    assert len(image_parts) == 2, "Image must have format registry/name:tag"
    
    image_name, image_tag = image_parts
    assert image_name, "Image name must not be empty"
    assert image_tag, "Image tag (version) must not be empty"
    
    # Should be percona/proxysql2 or similar
    assert 'proxysql' in image_name.lower(), "Image should be ProxySQL image"


@pytest.mark.unit
def test_proxysql_image_version_pinned():
    """Test that ProxySQL image version is pinned (not 'latest')."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    image = values['proxysql']['image']
    image_tag = image.split(':')[1]
    
    assert image_tag != 'latest', "Image tag must not be 'latest' - use specific version for stability"
    
    # Version should be in format like 2.7.3 or 2.x.x
    version_pattern = r'^\d+\.\d+\.\d+'
    assert re.match(version_pattern, image_tag), \
        f"Image tag should be a version number, not '{image_tag}'"


@pytest.mark.unit
def test_proxysql_image_compatibility():
    """Test that ProxySQL image version is compatible with Percona Operator v1.18."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    image = values['proxysql']['image']
    image_tag = image.split(':')[1]
    
    # Extract version numbers
    version_match = re.match(r'^(\d+)\.(\d+)\.(\d+)', image_tag)
    if version_match:
        major, minor, patch = map(int, version_match.groups())
        
        # ProxySQL 2.7.x is recommended for Percona Operator v1.18
        assert major == 2, "ProxySQL major version should be 2"
        assert minor >= 6, "ProxySQL minor version should be >= 6 for Percona Operator v1.18"


@pytest.mark.unit
def test_pxc_image_version_uses_operator_default():
    """Test that PXC image version uses operator defaults (best practice)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    pxc = values['pxc']
    
    # PXC image should use operator default (operator manages version)
    # If image is not specified, operator will use recommended version
    # This is preferred over hardcoding PXC version
    
    # If image is specified, it should be pinned
    if 'image' in pxc:
        image = pxc['image']
        if image:
            assert ':' in image, "If PXC image is specified, it must include version tag"
            image_tag = image.split(':')[1]
            assert image_tag != 'latest', "PXC image tag must not be 'latest'"


@pytest.mark.unit
def test_image_registry_configured():
    """Test that images use appropriate registry (percona registry preferred)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # ProxySQL should use percona registry or official registry
    proxysql_image = values['proxysql']['image']
    
    # Should be from percona registry or official registry (not random)
    assert ('percona' in proxysql_image.lower() or 
            'quay.io' in proxysql_image.lower() or
            proxysql_image.startswith('percona/')), \
        "ProxySQL image should be from Percona or official registry"


@pytest.mark.unit
def test_image_pull_policy_not_always():
    """Test that image pull policy is not 'Always' (security best practice)."""
    # Note: This test documents best practice
    # Percona Operator typically uses IfNotPresent or the operator's default
    # 'Always' is not recommended for production as it can cause unnecessary pulls
    
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # Check if imagePullPolicy is specified anywhere
    # If specified, it should not be 'Always' for production workloads
    
    # ProxySQL
    if 'imagePullPolicy' in values.get('proxysql', {}):
        pull_policy = values['proxysql']['imagePullPolicy']
        assert pull_policy != 'Always', \
            "imagePullPolicy should not be 'Always' - use 'IfNotPresent' or operator default"
    
    # PXC
    if 'imagePullPolicy' in values.get('pxc', {}):
        pull_policy = values['pxc']['imagePullPolicy']
        assert pull_policy != 'Always', \
            "imagePullPolicy should not be 'Always' - use 'IfNotPresent' or operator default"


"""
Unit tests for container image version validation.
Validates that image versions match Percona Operator v1.18 recommendations.
"""
import os
import yaml
import pytest
import re
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_proxysql_image_version(request):
    """Test that ProxySQL image version is specified and valid."""
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    
    values, path = get_values_for_test()
    
    proxysql = values['proxysql']
    log_check(
        criterion="ProxySQL image must be specified in values",
        expected="image key present",
        actual=f"keys={sorted(list(proxysql.keys()))}",
        source=path,
    )
    assert 'image' in proxysql, "ProxySQL image must be specified"
    
    image = proxysql['image']
    # Image format: registry/name:tag
    log_check("Image must include version tag separator ':'", ": present", f"{':' in image}", source=path)
    assert ':' in image, "Image must include version tag"
    
    image_parts = image.split(':')
    log_check("Image format must be registry/name:tag", "parts=2", f"parts={len(image_parts)}", source=path)
    assert len(image_parts) == 2, "Image must have format registry/name:tag"
    
    image_name, image_tag = image_parts
    log_check("Image name must not be empty", "non-empty", f"empty={not bool(image_name)}", source=path)
    assert image_name, "Image name must not be empty"
    log_check("Image tag must not be empty", "non-empty", f"empty={not bool(image_tag)}", source=path)
    assert image_tag, "Image tag (version) must not be empty"
    
    # Should be percona/proxysql2 or similar
    log_check("Image name should include 'proxysql'", "contains", f"contains={'proxysql' in image_name.lower()}", source=path)
    assert 'proxysql' in image_name.lower(), "Image should be ProxySQL image"


@pytest.mark.unit
def test_proxysql_image_version_pinned(request):
    """Test that ProxySQL image version is pinned (not 'latest')."""
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    
    values, path = get_values_for_test()
    
    image = values['proxysql']['image']
    image_tag = image.split(':')[1]
    
    log_check("Image tag must not be 'latest'", "!= latest", f"{image_tag}", source=path)
    assert image_tag != 'latest', "Image tag must not be 'latest' - use specific version for stability"
    
    # Version should be in format like 2.7.3 or 2.x.x
    version_pattern = r'^\d+\.\d+\.\d+'
    log_check("Image tag should be semantic version (e.g., 2.7.3)", version_pattern, f"{image_tag}", source=path)
    assert re.match(version_pattern, image_tag), \
        f"Image tag should be a version number, not '{image_tag}'"


@pytest.mark.unit
def test_proxysql_image_compatibility(request):
    """Test that ProxySQL image version is compatible with Percona Operator v1.18."""
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    
    values, path = get_values_for_test()
    
    image = values['proxysql']['image']
    image_tag = image.split(':')[1]
    
    # Extract version numbers
    version_match = re.match(r'^(\d+)\.(\d+)\.(\d+)', image_tag)
    if version_match:
        major, minor, patch = map(int, version_match.groups())
        
        # ProxySQL 2.7.x is recommended for Percona Operator v1.18
        log_check("ProxySQL major version should be 2", "2", f"{major}", source=path)
        assert major == 2, "ProxySQL major version should be 2"
        log_check("ProxySQL minor version should be >= 6", ">= 6", f"{minor}", source=path)
        assert minor >= 6, "ProxySQL minor version should be >= 6 for Percona Operator v1.18"


@pytest.mark.unit
def test_pxc_image_version_uses_operator_default():
    """Test that PXC image version uses operator defaults (best practice)."""
    values, path = get_values_for_test()
    
    pxc = values['pxc']
    
    # PXC image should use operator default (operator manages version)
    # If image is not specified, operator will use recommended version
    # This is preferred over hardcoding PXC version
    
    # If image is specified, it should be pinned
    if 'image' in pxc:
        image = pxc['image']
        if image:
            log_check("If PXC image is specified, it must include version tag separator ':'", ": present", f"{':' in image}", source=path)
            assert ':' in image, "If PXC image is specified, it must include version tag"
            image_tag = image.split(':')[1]
            log_check("PXC image tag must not be 'latest'", "!= latest", f"{image_tag}", source=path)
            assert image_tag != 'latest', "PXC image tag must not be 'latest'"


@pytest.mark.unit
def test_image_registry_configured(request):
    """Test that images use appropriate registry (percona registry preferred)."""
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    
    values, path = get_values_for_test()
    
    # ProxySQL should use percona registry or official registry
    proxysql_image = values['proxysql']['image']
    
    # Should be from percona registry or official registry (not random)
    valid_registry = ('percona' in proxysql_image.lower() or 
            'quay.io' in proxysql_image.lower() or
            proxysql_image.startswith('percona/'))
    log_check("ProxySQL image should be from Percona or official registry", "percona/quay.io/percona/ prefix", f"ok={valid_registry}", source=path)
    assert valid_registry, \
        "ProxySQL image should be from Percona or official registry"


@pytest.mark.unit
def test_image_pull_policy_not_always():
    """Test that image pull policy is not 'Always' (security best practice)."""
    values, path = get_values_for_test()
    
    # Check if imagePullPolicy is specified anywhere
    # If specified, it should not be 'Always' for production workloads
    
    # PXC
    if 'imagePullPolicy' in values.get('pxc', {}):
        pull_policy = values['pxc']['imagePullPolicy']
        log_check("PXC imagePullPolicy should not be 'Always'", "!= Always", f"{pull_policy}", source=path)
        assert pull_policy != 'Always', \
            "imagePullPolicy should not be 'Always' - use 'IfNotPresent' or operator default"
    
    # ProxySQL (only if enabled)
    if values.get('proxysql', {}).get('enabled') and 'imagePullPolicy' in values.get('proxysql', {}):
        pull_policy = values['proxysql']['imagePullPolicy']
        log_check("ProxySQL imagePullPolicy should not be 'Always'", "!= Always", f"{pull_policy}", source=path)
        assert pull_policy != 'Always', \
            "imagePullPolicy should not be 'Always' - use 'IfNotPresent' or operator default"
    
    # HAProxy (only if enabled)
    if values.get('haproxy', {}).get('enabled') and 'imagePullPolicy' in values.get('haproxy', {}):
        pull_policy = values['haproxy']['imagePullPolicy']
        log_check("HAProxy imagePullPolicy should not be 'Always'", "!= Always", f"{pull_policy}", source=path)
        assert pull_policy != 'Always', \
            "imagePullPolicy should not be 'Always' - use 'IfNotPresent' or operator default"

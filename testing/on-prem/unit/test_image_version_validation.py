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
def test_pxc_image_version_pinned():
    """Test that PXC image version is 8.4.6 (repository path can vary)."""
    values, path = get_values_for_test()
    
    pxc = values['pxc']
    expected_version = "8.4.6"
    
    # On-prem should have PXC image explicitly specified and pinned
    log_check(
        criterion="PXC image must be specified in values",
        expected="image key present",
        actual=f"present={'image' in pxc}",
        source=path
    )
    assert 'image' in pxc, "PXC image must be specified for on-prem deployments"
    
    actual_image = pxc['image']
    
    # Extract version from image (format: repository/image:version)
    if ':' not in actual_image:
        pytest.fail(f"PXC image must include version tag, got: {actual_image}")
    
    actual_version = actual_image.split(':')[-1]
    
    log_check(
        criterion="PXC image version must be 8.4.6",
        expected=expected_version,
        actual=actual_version,
        source=path
    )
    assert actual_version == expected_version, \
        f"PXC image version must be {expected_version}, got {actual_version} (full image: {actual_image})"


@pytest.mark.unit
def test_haproxy_image_version_pinned():
    """Test that HAProxy image is pinned to approved version for on-prem."""
    values, path = get_values_for_test()
    
    haproxy = values.get('haproxy', {})
    expected_image = "percona/haproxy:2.8.15"
    
    # On-prem uses HAProxy, verify it's enabled
    if not haproxy.get('enabled'):
        pytest.skip("HAProxy is not enabled in this configuration")
    
    # On-prem should have HAProxy image explicitly specified and pinned
    log_check(
        criterion="HAProxy image must be specified in values",
        expected="image key present",
        actual=f"present={'image' in haproxy}",
        source=path
    )
    assert 'image' in haproxy, "HAProxy image must be specified for on-prem deployments"
    
    actual_image = haproxy['image']
    log_check(
        criterion="HAProxy image must match approved version",
        expected=expected_image,
        actual=actual_image,
        source=path
    )
    assert actual_image == expected_image, \
        f"HAProxy image must be {expected_image} for on-prem, got {actual_image}"


@pytest.mark.unit
def test_operator_image_version_pinned():
    """Test that Percona Operator image is pinned to approved version for on-prem."""
    from conftest import FLEET_RENDERED_MANIFEST
    
    expected_image = "percona/percona-xtradb-cluster-operator:1.18.0"
    
    # Load the full Fleet-rendered manifest (contains all Kubernetes resources)
    if not FLEET_RENDERED_MANIFEST or not os.path.exists(FLEET_RENDERED_MANIFEST):
        pytest.skip("Fleet rendered manifest not available")
    
    with open(FLEET_RENDERED_MANIFEST, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    # Find the operator Deployment
    operator_deployment = None
    for doc in docs:
        if doc and doc.get('kind') == 'Deployment':
            # Look for operator deployment (usually has 'operator' in the name)
            name = doc.get('metadata', {}).get('name', '')
            if 'operator' in name.lower():
                operator_deployment = doc
                break
    
    if not operator_deployment:
        pytest.skip("Operator Deployment not found in rendered manifest")
    
    # Extract operator container image
    containers = operator_deployment.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
    
    log_check(
        criterion="Operator Deployment must have at least one container",
        expected="> 0",
        actual=f"{len(containers)} containers",
        source=FLEET_RENDERED_MANIFEST
    )
    assert len(containers) > 0, "Operator Deployment must have at least one container"
    
    # The operator image should be in the first (or only) container
    operator_image = containers[0].get('image')
    
    log_check(
        criterion="Operator container image must be specified",
        expected="image present",
        actual=f"image={operator_image}",
        source=FLEET_RENDERED_MANIFEST
    )
    assert operator_image, "Operator container must have image specified"
    
    log_check(
        criterion="Operator image must match approved version",
        expected=expected_image,
        actual=operator_image,
        source=FLEET_RENDERED_MANIFEST
    )
    assert operator_image == expected_image, \
        f"Operator image must be {expected_image} for on-prem, got {operator_image}"


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
    
    # HAProxy (only if enabled - on-prem uses HAProxy)
    if values.get('haproxy', {}).get('enabled') and 'imagePullPolicy' in values.get('haproxy', {}):
        pull_policy = values['haproxy']['imagePullPolicy']
        log_check("HAProxy imagePullPolicy should not be 'Always'", "!= Always", f"{pull_policy}", source=path)
        assert pull_policy != 'Always', \
            "imagePullPolicy should not be 'Always' - use 'IfNotPresent' or operator default"

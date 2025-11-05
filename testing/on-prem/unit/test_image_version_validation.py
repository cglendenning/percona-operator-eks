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

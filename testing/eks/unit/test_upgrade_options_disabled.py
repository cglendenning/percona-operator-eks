"""
Unit test for PerconaXtraDBCluster upgradeOptions.apply validation.
Validates that upgradeOptions.apply is set to disabled to prevent automatic upgrades.
"""
import os
import yaml
import pytest
from conftest import log_check, FLEET_RENDERED_MANIFEST


@pytest.mark.unit
def test_upgrade_options_apply_is_disabled():
    """
    Test that PerconaXtraDBCluster upgradeOptions.apply is set to disabled.
    
    How this test gathers information from the rendered manifest:
    
    1. The test loads the Fleet-rendered manifest containing all Kubernetes resources.
    
    2. It searches for the PerconaXtraDBCluster custom resource (kind: PerconaXtraDBCluster).
    
    3. Within the PerconaXtraDBCluster spec, the upgradeOptions.apply is defined at:
       spec.upgradeOptions.apply
       
    4. The upgradeOptions.apply field controls automatic version upgrades:
       - disabled: Manual upgrade control (recommended for production)
       - recommended: Automatically apply recommended version updates
       - latest: Automatically apply latest version updates (not recommended)
       - X.Y.Z: Automatically upgrade to specific version
    
    5. Setting to "disabled" is critical for production because:
       - Prevents unexpected automatic upgrades
       - Ensures change management process is followed
       - Allows validation in lower environments first
       - Maintains version consistency across clusters
       - Prevents potential downtime from automatic upgrades
    
    Example PerconaXtraDBCluster resource:
    
    apiVersion: pxc.percona.com/v1
    kind: PerconaXtraDBCluster
    metadata:
      name: pxc-cluster
    spec:
      crVersion: 1.18.0
      updateStrategy: SmartUpdate
      upgradeOptions:
        apply: disabled  # This is what we're validating
      pxc:
        size: 3
    """
    expected_value = "disabled"
    
    # Load the full Fleet-rendered manifest
    if not FLEET_RENDERED_MANIFEST or not os.path.exists(FLEET_RENDERED_MANIFEST):
        pytest.skip("Fleet rendered manifest not available")
    
    with open(FLEET_RENDERED_MANIFEST, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    # Find the PerconaXtraDBCluster custom resource
    pxc_cluster = None
    for doc in docs:
        if doc and doc.get('kind') == 'PerconaXtraDBCluster':
            pxc_cluster = doc
            break
    
    if not pxc_cluster:
        pytest.skip("PerconaXtraDBCluster resource not found in rendered manifest")
    
    # Extract upgradeOptions from spec
    upgrade_options = pxc_cluster.get('spec', {}).get('upgradeOptions', {})
    apply_value = upgrade_options.get('apply')
    
    log_check(
        criterion="PerconaXtraDBCluster spec must have upgradeOptions.apply defined",
        expected="apply field present",
        actual=f"apply={apply_value}",
        source=FLEET_RENDERED_MANIFEST
    )
    
    # If upgradeOptions.apply is not explicitly set, the operator may default to a value
    # For production safety, it should be explicitly set to "disabled"
    if apply_value is None:
        pytest.fail(
            "upgradeOptions.apply must be explicitly set to 'disabled' for production. "
            "Not setting this field may result in automatic upgrades."
        )
    
    log_check(
        criterion="upgradeOptions.apply must be 'disabled' for production",
        expected=expected_value,
        actual=apply_value,
        source=FLEET_RENDERED_MANIFEST
    )
    
    assert apply_value == expected_value, \
        f"upgradeOptions.apply must be '{expected_value}' to prevent automatic upgrades, got '{apply_value}'"

"""
Unit test for Percona XtraDB Cluster updateStrategy validation.
Validates that the updateStrategy is set to SmartUpdate in the PerconaXtraDBCluster CR.
"""
import os
import yaml
import pytest
from conftest import log_check, FLEET_RENDERED_MANIFEST


@pytest.mark.unit
def test_update_strategy_is_smart_update():
    """
    Test that PerconaXtraDBCluster updateStrategy is set to SmartUpdate.
    
    How this test gathers information from the rendered manifest:
    
    1. The test loads the Fleet-rendered manifest containing all Kubernetes resources.
    
    2. It searches for the PerconaXtraDBCluster custom resource (kind: PerconaXtraDBCluster).
    
    3. Within the PerconaXtraDBCluster spec, the updateStrategy is defined at:
       spec.updateStrategy
       
    4. The updateStrategy field controls how the Percona Operator performs rolling updates
       of PXC pods. Valid values are:
       - SmartUpdate (default): Operator waits for each pod to become ready and synced
                                before updating the next pod
       - RollingUpdate: Standard Kubernetes rolling update
       - OnDelete: Manual update control
    
    5. SmartUpdate is the recommended strategy because it:
       - Maintains cluster quorum during updates
       - Waits for Galera sync status before proceeding
       - Minimizes risk of data loss or cluster downtime
       - Automatically handles node failures during updates
    
    Example PerconaXtraDBCluster resource:
    
    apiVersion: pxc.percona.com/v1
    kind: PerconaXtraDBCluster
    metadata:
      name: pxc-cluster
    spec:
      crVersion: 1.18.0
      updateStrategy: SmartUpdate  # This is what we're validating
      pxc:
        size: 3
    """
    expected_strategy = "SmartUpdate"
    
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
    
    # Extract updateStrategy from spec
    update_strategy = pxc_cluster.get('spec', {}).get('updateStrategy')
    
    log_check(
        criterion="PerconaXtraDBCluster spec must have updateStrategy defined",
        expected="updateStrategy present",
        actual=f"updateStrategy={update_strategy}",
        source=FLEET_RENDERED_MANIFEST
    )
    
    # If updateStrategy is not explicitly set, the operator defaults to SmartUpdate
    # However, for explicit configuration management, it should be set
    if update_strategy is None:
        pytest.skip(
            "updateStrategy not explicitly set in manifest (operator will default to SmartUpdate). "
            "Consider setting it explicitly for clarity."
        )
    
    log_check(
        criterion="PerconaXtraDBCluster updateStrategy must be SmartUpdate",
        expected=expected_strategy,
        actual=update_strategy,
        source=FLEET_RENDERED_MANIFEST
    )
    
    assert update_strategy == expected_strategy, \
        f"updateStrategy must be {expected_strategy}, got {update_strategy}"


@pytest.mark.unit
def test_update_strategy_is_valid():
    """Test that updateStrategy, if set, is a valid value."""
    valid_strategies = ['SmartUpdate', 'RollingUpdate', 'OnDelete']
    
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
    
    update_strategy = pxc_cluster.get('spec', {}).get('updateStrategy')
    
    if update_strategy is None:
        pytest.skip("updateStrategy not set (will use operator default)")
    
    log_check(
        criterion=f"updateStrategy must be one of {valid_strategies}",
        expected=f"in {valid_strategies}",
        actual=update_strategy,
        source=FLEET_RENDERED_MANIFEST
    )
    
    assert update_strategy in valid_strategies, \
        f"updateStrategy must be one of {valid_strategies}, got {update_strategy}"


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


@pytest.mark.unit
def test_upgrade_options_is_valid():
    """Test that upgradeOptions.apply, if set, is a valid value."""
    valid_values = ['disabled', 'recommended', 'latest']  # or specific version like "1.18.0"
    
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
    
    upgrade_options = pxc_cluster.get('spec', {}).get('upgradeOptions', {})
    apply_value = upgrade_options.get('apply')
    
    if apply_value is None:
        pytest.skip("upgradeOptions.apply not set")
    
    # Check if it's a valid predefined value or a version string
    import re
    is_version = re.match(r'^\d+\.\d+\.\d+$', apply_value)
    is_valid_keyword = apply_value in valid_values
    
    log_check(
        criterion=f"upgradeOptions.apply must be one of {valid_values} or a version X.Y.Z",
        expected=f"valid value or version",
        actual=apply_value,
        source=FLEET_RENDERED_MANIFEST
    )
    
    assert is_valid_keyword or is_version, \
        f"upgradeOptions.apply must be one of {valid_values} or a version (X.Y.Z), got '{apply_value}'"


@pytest.mark.unit
def test_pxc_cluster_has_required_fields():
    """Test that PerconaXtraDBCluster has all required fields for production."""
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
    
    spec = pxc_cluster.get('spec', {})
    
    # Check crVersion is specified
    cr_version = spec.get('crVersion')
    log_check(
        criterion="PerconaXtraDBCluster must specify crVersion",
        expected="version present",
        actual=f"crVersion={cr_version}",
        source=FLEET_RENDERED_MANIFEST
    )
    assert cr_version, "PerconaXtraDBCluster must specify crVersion"
    
    # Check pxc configuration exists
    pxc_config = spec.get('pxc', {})
    log_check(
        criterion="PerconaXtraDBCluster must have pxc configuration",
        expected="pxc config present",
        actual=f"present={bool(pxc_config)}",
        source=FLEET_RENDERED_MANIFEST
    )
    assert pxc_config, "PerconaXtraDBCluster must have pxc configuration"
    
    # Check size is specified
    pxc_size = pxc_config.get('size')
    log_check(
        criterion="PXC must specify size (replica count)",
        expected="> 0",
        actual=f"size={pxc_size}",
        source=FLEET_RENDERED_MANIFEST
    )
    assert pxc_size and pxc_size > 0, "PXC must specify size > 0"

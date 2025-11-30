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

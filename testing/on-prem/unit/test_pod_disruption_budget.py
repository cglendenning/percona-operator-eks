"""
Unit tests for Pod Disruption Budget (PDB) configuration.
Validates that PDBs are configured to ensure high availability.
"""
import os
import yaml
import pytest
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_pxc_pod_disruption_budget_exists():
    """Test that PXC has Pod Disruption Budget configured."""
    values, path = get_values_for_test()
    
    criterion = "PXC values must include podDisruptionBudget key"
    expected_desc = "key present"
    actual_desc = f"keys={sorted(list(values['pxc'].keys()))}"
    log_check(criterion=criterion, expected=expected_desc, actual=actual_desc, source=path)
    assert 'podDisruptionBudget' in values['pxc'], "PXC must have Pod Disruption Budget configured"


@pytest.mark.unit
def test_pdb_allows_rolling_updates_and_maintains_quorum():
    """Test that PDB settings allow safe rolling updates while maintaining quorum."""
    values, path = get_values_for_test()
    
    node_count = values['pxc']['size']
    pxc_pdb = values['pxc']['podDisruptionBudget']
    max_unavailable = pxc_pdb.get('maxUnavailable', 0)
    
    # For a 3-node cluster, maxUnavailable=1 allows rolling updates
    # while ensuring at least 2 nodes remain available (maintaining quorum)
    log_check(
        criterion="PXC PDB maxUnavailable must be 1 for 3-node cluster",
        expected="1",
        actual=f"pxc pdb maxUnavailable = {max_unavailable}",
        source=path,
    )
    assert max_unavailable == 1, \
        "PXC PDB maxUnavailable should be 1 to maintain quorum and allow rolling updates"
    
    # Verify quorum is maintained: (n/2) + 1 nodes must be available
    available_during_disruption = node_count - max_unavailable
    quorum = (node_count // 2) + 1
    
    log_check(
        criterion=f"For {node_count}-node cluster, available during disruption must be >= quorum {quorum}",
        expected=f">= {quorum}",
        actual=f"available_during_disruption = {available_during_disruption}",
        source=path,
    )
    assert available_during_disruption >= quorum, \
        f"For {node_count}-node cluster, maxUnavailable={max_unavailable} must maintain quorum of {quorum}"
    
    # Check HAProxy PDB (on-prem uses HAProxy)
    if values.get('haproxy', {}).get('enabled'):
        haproxy_pdb = values['haproxy'].get('podDisruptionBudget', {})
        if haproxy_pdb:
            max_unavailable = haproxy_pdb.get('maxUnavailable', 0)
            log_check(
                criterion="HAProxy PDB maxUnavailable should be configured",
                expected=">= 0",
                actual=f"haproxy pdb maxUnavailable = {max_unavailable}",
                source=path,
            )
            assert max_unavailable >= 0



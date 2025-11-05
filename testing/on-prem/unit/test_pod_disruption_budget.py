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
def test_pxc_pod_disruption_budget_max_unavailable():
    """Test that PXC PDB has appropriate maxUnavailable setting."""
    values, path = get_values_for_test()
    
    pdb = values['pxc']['podDisruptionBudget']
    
    # For a 3-node cluster, maxUnavailable should be 1 to maintain quorum
    # This ensures at least 2 nodes remain available during maintenance
    max_unavailable = pdb.get('maxUnavailable', 0)
    
    # Should be 1 for 3-node cluster (allows 1 pod to be disrupted)
    # For larger clusters, this might be configurable, but 1 is safe
    log_check(
        criterion="PXC PDB maxUnavailable must be 1 for quorum on 3-node cluster",
        expected="1",
        actual=f"pxc pdb maxUnavailable = {max_unavailable}",
        source=path,
    )
    assert max_unavailable == 1, \
        "PXC PDB maxUnavailable should be 1 to maintain quorum during maintenance"


@pytest.mark.unit
def test_proxysql_pod_disruption_budget_exists(request):
    """Test that ProxySQL has Pod Disruption Budget configured."""
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    
    values, path = get_values_for_test()
    
    criterion = "ProxySQL values must include podDisruptionBudget key"
    expected_desc = "key present"
    actual_desc = f"keys={sorted(list(values['proxysql'].keys()))}"
    log_check(criterion=criterion, expected=expected_desc, actual=actual_desc, source=path)
    assert 'podDisruptionBudget' in values['proxysql'], "ProxySQL must have Pod Disruption Budget configured"


@pytest.mark.unit
def test_proxysql_pod_disruption_budget_max_unavailable(request):
    """Test that ProxySQL PDB has appropriate maxUnavailable setting."""
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    
    values, path = get_values_for_test()
    
    pdb = values['proxysql']['podDisruptionBudget']
    
    # ProxySQL should also have maxUnavailable=1 to ensure availability
    max_unavailable = pdb.get('maxUnavailable', 0)
    log_check(
        criterion="ProxySQL PDB maxUnavailable must be 1 to ensure availability",
        expected="1",
        actual=f"proxysql pdb maxUnavailable = {max_unavailable}",
        source=path,
    )
    assert max_unavailable == 1, \
        "ProxySQL PDB maxUnavailable should be 1 to ensure high availability"


@pytest.mark.unit
def test_pdb_allows_rolling_updates(request):
    """Test that PDB settings allow safe rolling updates."""
    values, path = get_values_for_test()
    
    # For 3-node cluster with maxUnavailable=1
    # This allows rolling updates: update 1 pod at a time while 2 remain available
    pxc_pdb = values['pxc']['podDisruptionBudget']
    
    log_check(
        criterion="Rolling updates: PXC PDB maxUnavailable must be 1",
        expected="1",
        actual=f"pxc pdb maxUnavailable = {pxc_pdb.get('maxUnavailable')}",
        source=path,
    )
    assert pxc_pdb.get('maxUnavailable') == 1
    
    # Check proxy PDB (ProxySQL or HAProxy depending on configuration)
    if values.get('proxysql', {}).get('enabled') and request.config.getoption('--proxysql'):
        proxysql_pdb = values['proxysql']['podDisruptionBudget']
        log_check(
            criterion="Rolling updates: ProxySQL PDB maxUnavailable must be 1",
            expected="1",
            actual=f"proxysql pdb maxUnavailable = {proxysql_pdb.get('maxUnavailable')}",
            source=path,
        )
        assert proxysql_pdb.get('maxUnavailable') == 1
    elif values.get('haproxy', {}).get('enabled'):
        haproxy_pdb = values['haproxy'].get('podDisruptionBudget', {})
        if haproxy_pdb:
            max_unavailable = haproxy_pdb.get('maxUnavailable', 0)
            log_check(
                criterion="Rolling updates: HAProxy PDB maxUnavailable should be configured",
                expected=">= 0",
                actual=f"haproxy pdb maxUnavailable = {max_unavailable}",
                source=path,
            )
            assert max_unavailable >= 0
    
    # This configuration allows safe rolling updates while maintaining service availability


@pytest.mark.unit
def test_pdb_maintains_quorum():
    """Test that PDB settings maintain quorum for PXC cluster."""
    values, path = get_values_for_test()
    
    node_count = values['pxc']['size']
    pdb = values['pxc']['podDisruptionBudget']
    max_unavailable = pdb.get('maxUnavailable', 0)
    
    # For quorum: (n/2) + 1 nodes must be available
    # With maxUnavailable=1, for 3-node: 2 available (quorum OK)
    # For 5-node: 4 available (quorum OK)
    # For 7-node: 6 available (quorum OK)
    available_during_disruption = node_count - max_unavailable
    
    # Quorum = floor(n/2) + 1
    quorum = (node_count // 2) + 1
    
    log_check(
        criterion=f"For {node_count}-node cluster, available during disruption must be >= quorum {quorum}",
        expected=f">= {quorum}",
        actual=f"available_during_disruption = {available_during_disruption} (maxUnavailable={max_unavailable})",
        source=path,
    )
    assert available_during_disruption >= quorum, \
        f"For {node_count}-node cluster, maxUnavailable={max_unavailable} must maintain quorum of {quorum}"

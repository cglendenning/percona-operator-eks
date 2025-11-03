"""
Unit tests for Pod Disruption Budget (PDB) configuration.
Validates that PDBs are configured to ensure high availability.
"""
import os
import yaml
import pytest


@pytest.mark.unit
def test_pxc_pod_disruption_budget_exists():
    """Test that PXC has Pod Disruption Budget configured."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    assert 'podDisruptionBudget' in values['pxc'], "PXC must have Pod Disruption Budget configured"


@pytest.mark.unit
def test_pxc_pod_disruption_budget_max_unavailable():
    """Test that PXC PDB has appropriate maxUnavailable setting."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    pdb = values['pxc']['podDisruptionBudget']
    
    # For a 3-node cluster, maxUnavailable should be 1 to maintain quorum
    # This ensures at least 2 nodes remain available during maintenance
    max_unavailable = pdb.get('maxUnavailable', 0)
    
    # Should be 1 for 3-node cluster (allows 1 pod to be disrupted)
    # For larger clusters, this might be configurable, but 1 is safe
    assert max_unavailable == 1, \
        "PXC PDB maxUnavailable should be 1 to maintain quorum during maintenance"


@pytest.mark.unit
def test_proxysql_pod_disruption_budget_exists():
    """Test that ProxySQL has Pod Disruption Budget configured."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    assert 'podDisruptionBudget' in values['proxysql'], "ProxySQL must have Pod Disruption Budget configured"


@pytest.mark.unit
def test_proxysql_pod_disruption_budget_max_unavailable():
    """Test that ProxySQL PDB has appropriate maxUnavailable setting."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    pdb = values['proxysql']['podDisruptionBudget']
    
    # ProxySQL should also have maxUnavailable=1 to ensure availability
    max_unavailable = pdb.get('maxUnavailable', 0)
    assert max_unavailable == 1, \
        "ProxySQL PDB maxUnavailable should be 1 to ensure high availability"


@pytest.mark.unit
def test_pdb_allows_rolling_updates():
    """Test that PDB settings allow safe rolling updates."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # For 3-node cluster with maxUnavailable=1
    # This allows rolling updates: update 1 pod at a time while 2 remain available
    pxc_pdb = values['pxc']['podDisruptionBudget']
    proxysql_pdb = values['proxysql']['podDisruptionBudget']
    
    assert pxc_pdb.get('maxUnavailable') == 1
    assert proxysql_pdb.get('maxUnavailable') == 1
    
    # This configuration allows safe rolling updates while maintaining service availability


@pytest.mark.unit
def test_pdb_maintains_quorum():
    """Test that PDB settings maintain quorum for PXC cluster."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    
    # Test with different node counts
    for node_count in [3, 5, 7]:
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
            content = content.replace('{{NODES}}', str(node_count))
            values = yaml.safe_load(content)
        
        pdb = values['pxc']['podDisruptionBudget']
        max_unavailable = pdb.get('maxUnavailable', 0)
        
        # For quorum: (n/2) + 1 nodes must be available
        # With maxUnavailable=1, for 3-node: 2 available (quorum OK)
        # For 5-node: 4 available (quorum OK)
        # For 7-node: 6 available (quorum OK)
        available_during_disruption = node_count - max_unavailable
        
        # Quorum = floor(n/2) + 1
        quorum = (node_count // 2) + 1
        
        assert available_during_disruption >= quorum, \
            f"For {node_count}-node cluster, maxUnavailable={max_unavailable} must maintain quorum of {quorum}"


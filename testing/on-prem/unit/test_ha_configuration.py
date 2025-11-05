"""
Unit tests for High Availability (HA) configuration.
Validates HA settings match Percona best practices for v1.18.
"""
import os
import yaml
import pytest
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_minimum_cluster_size_for_ha():
    """Test that cluster size meets minimum for high availability."""
    values, path = get_values_for_test()
    
    pxc_size = values['pxc']['size']
    proxysql_size = values['proxysql']['size']
    
    assert pxc_size >= 3, "PXC requires minimum 3 nodes for high availability"
    assert proxysql_size >= 3, "ProxySQL requires minimum 3 nodes for high availability"


@pytest.mark.unit
def test_odd_node_count_preference():
    """Test that odd node counts are preferred for quorum (3, 5, 7 nodes)."""
    values, path = get_values_for_test()
    
    node_count = values['pxc']['size']

    # Emit explicit criterion/result for verbose clarity
    criterion = "PXC node count (<=5) should be one of [3, 5] to maintain quorum preference"
    expected_desc = "one of [3, 5]"
    actual_desc = f"pxc size = {node_count}"
    log_check(criterion=criterion, expected=expected_desc, actual=actual_desc, source=path)
    
    # While even numbers > 4 are acceptable, odd numbers are preferred
    # This test documents the best practice
    if node_count <= 5:
        # For small clusters (<= 5), odd is strongly recommended
        # 3 is minimum, 5 is also good
        assert node_count in [3, 5], \
            f"For clusters <= 5 nodes, odd count is preferred. Found {node_count}"


@pytest.mark.unit
def test_pdb_maintains_quorum():
    """Test that PDB settings maintain quorum during disruptions."""
    values, path = get_values_for_test()
    
    node_count = values['pxc']['size']
    pdb = values['pxc']['podDisruptionBudget']
    max_unavailable = pdb.get('maxUnavailable', 0)
    
    # Calculate quorum requirement: floor(n/2) + 1
    quorum = (node_count // 2) + 1
    available_during_disruption = node_count - max_unavailable
    
    assert available_during_disruption >= quorum, \
        f"For {node_count}-node cluster, PDB must maintain quorum of {quorum}. " \
        f"With maxUnavailable={max_unavailable}, only {available_during_disruption} would be available"


@pytest.mark.unit
def test_multi_az_anti_affinity():
    """Test that anti-affinity rules ensure multi-AZ deployment."""
    values, path = get_values_for_test()
    
    # Both PXC and ProxySQL should have zone-based anti-affinity
    pxc_rules = values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    proxysql_rules = values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Check for zone or hostname topology key (on-prem may use hostname)
    pxc_has_topology = any(
        rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone', 'kubernetes.io/hostname']
        for rule in pxc_rules
    )
    
    proxysql_has_topology = any(
        rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone', 'kubernetes.io/hostname']
        for rule in proxysql_rules
    )
    
    assert pxc_has_topology, "PXC must have topology-based anti-affinity for HA"
    assert proxysql_has_topology, "ProxySQL must have topology-based anti-affinity for HA"


@pytest.mark.unit
def test_backup_enabled_for_ha():
    """Test that backups are enabled for disaster recovery."""
    values, path = get_values_for_test()
    
    assert values['backup']['enabled'] is True, \
        "Backups must be enabled for disaster recovery in HA deployments"


@pytest.mark.unit
def test_pitr_enabled_for_point_in_time_recovery():
    """Test that PITR is enabled for point-in-time recovery."""
    values, path = get_values_for_test()
    
    assert values['backup']['pitr']['enabled'] is True, \
        "PITR must be enabled for point-in-time recovery in HA deployments"


@pytest.mark.unit
def test_proxysql_enabled_for_ha():
    """Test that ProxySQL is enabled (required for HA load balancing)."""
    values, path = get_values_for_test()
    
    assert values['proxysql']['enabled'] is True, \
        "ProxySQL must be enabled for HA load balancing and connection management"


@pytest.mark.unit
def test_haproxy_disabled_when_proxysql_enabled():
    """Test that HAProxy is disabled when ProxySQL is enabled (avoids conflicts)."""
    values, path = get_values_for_test()
    
    # When ProxySQL is enabled, HAProxy should be disabled
    if values['proxysql']['enabled']:
        assert values['haproxy']['enabled'] is False, \
            "HAProxy should be disabled when ProxySQL is enabled to avoid conflicts"


@pytest.mark.unit
def test_statefulset_replicas_match_for_ha():
    """Test that PXC and ProxySQL replicas match (required for proper HA)."""
    values, path = get_values_for_test()
    
    pxc_size = values['pxc']['size']
    proxysql_size = values['proxysql']['size']
    
    # For proper HA, both should have matching replica counts
    assert pxc_size == proxysql_size, \
        f"PXC size ({pxc_size}) and ProxySQL size ({proxysql_size}) should match for proper HA configuration"


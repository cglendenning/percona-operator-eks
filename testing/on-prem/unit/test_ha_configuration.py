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
    
    assert pxc_size >= 3, "PXC requires minimum 3 nodes for high availability"
    
    # On-prem uses HAProxy by default
    if values.get('proxysql', {}).get('enabled'):
        proxysql_size = values['proxysql']['size']
        assert proxysql_size >= 3, "ProxySQL requires minimum 3 nodes for high availability"
    elif values.get('haproxy', {}).get('enabled'):
        haproxy_size = values['haproxy'].get('size', 1)
        assert haproxy_size >= 1, "HAProxy requires at least 1 node"


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
    
    # PXC should have topology-based anti-affinity
    pxc_rules = values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Check for zone or hostname topology key (on-prem may use hostname)
    pxc_has_topology = any(
        rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone', 'kubernetes.io/hostname']
        for rule in pxc_rules
    )
    
    assert pxc_has_topology, "PXC must have topology-based anti-affinity for HA"
    
    # On-prem uses HAProxy by default, check proxy anti-affinity accordingly
    if values.get('proxysql', {}).get('enabled'):
        proxysql_rules = values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
        proxysql_has_topology = any(
            rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone', 'kubernetes.io/hostname']
            for rule in proxysql_rules
        )
        assert proxysql_has_topology, "ProxySQL must have topology-based anti-affinity for HA"
    elif values.get('haproxy', {}).get('enabled'):
        # HAProxy anti-affinity is optional but recommended
        haproxy_affinity = values['haproxy'].get('affinity', {})
        if haproxy_affinity:
            haproxy_rules = haproxy_affinity.get('podAntiAffinity', {}).get('requiredDuringSchedulingIgnoredDuringExecution', [])
            if haproxy_rules:
                haproxy_has_topology = any(
                    rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone', 'kubernetes.io/hostname']
                    for rule in haproxy_rules
                )
                assert haproxy_has_topology, "HAProxy must have topology-based anti-affinity for HA"


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
def test_proxy_enabled_for_ha():
    """Test that a proxy is enabled (required for HA load balancing)."""
    values, path = get_values_for_test()
    
    # On-prem uses HAProxy by default, but ProxySQL is also valid
    proxysql_enabled = values.get('proxysql', {}).get('enabled', False)
    haproxy_enabled = values.get('haproxy', {}).get('enabled', False)
    
    assert proxysql_enabled or haproxy_enabled, \
        "Either ProxySQL or HAProxy must be enabled for HA load balancing and connection management"


@pytest.mark.unit
def test_only_one_proxy_enabled():
    """Test that only one proxy is enabled at a time (avoids conflicts)."""
    values, path = get_values_for_test()
    
    proxysql_enabled = values.get('proxysql', {}).get('enabled', False)
    haproxy_enabled = values.get('haproxy', {}).get('enabled', False)
    
    # Only one proxy should be enabled
    assert proxysql_enabled != haproxy_enabled or (not proxysql_enabled and not haproxy_enabled), \
        "Only one proxy (ProxySQL or HAProxy) should be enabled at a time to avoid conflicts"


@pytest.mark.unit
def test_statefulset_replicas_configured_for_ha():
    """Test that PXC and proxy replicas are properly configured for HA."""
    values, path = get_values_for_test()
    
    pxc_size = values['pxc']['size']
    
    # On-prem uses HAProxy by default
    if values.get('proxysql', {}).get('enabled'):
        proxysql_size = values['proxysql']['size']
        # For proper HA, both should have matching replica counts
        assert pxc_size == proxysql_size, \
            f"PXC size ({pxc_size}) and ProxySQL size ({proxysql_size}) should match for proper HA configuration"
    elif values.get('haproxy', {}).get('enabled'):
        haproxy_size = values['haproxy'].get('size', 1)
        assert haproxy_size >= 1, \
            f"HAProxy size ({haproxy_size}) must be at least 1 for HA configuration"


"""
Unit tests for anti-affinity rules configuration.
Validates that pods are distributed across availability zones per Percona best practices.
"""
import os
import yaml
import pytest
from tests.conftest import log_check, TOPOLOGY_KEY, get_values_for_test


@pytest.mark.unit
def test_pxc_anti_affinity_required():
    """Test that PXC has required anti-affinity rules."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    affinity = pxc.get('affinity', {})
    
    # Check for antiAffinityTopologyKey (PerconaXtraDBCluster CR format)
    assert 'antiAffinityTopologyKey' in affinity, "PXC must have affinity.antiAffinityTopologyKey configured"
    
    topology_key = affinity['antiAffinityTopologyKey']
    log_check(
        criterion="PXC antiAffinityTopologyKey must be set",
        expected="non-empty string",
        actual=f"antiAffinityTopologyKey={topology_key}",
        source=path,
    )
    assert topology_key, "PXC must have antiAffinityTopologyKey configured"


@pytest.mark.unit
def test_pxc_anti_affinity_topology_distribution():
    """Test that PXC anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    affinity = pxc.get('affinity', {})
    
    # Define accepted topology keys
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']
    
    assert 'antiAffinityTopologyKey' in affinity, "PXC must have affinity.antiAffinityTopologyKey configured"
    
    topology_key = affinity['antiAffinityTopologyKey']
    topo_found = topology_key in accepted_keys
    log_check(
        criterion=f"PXC antiAffinityTopologyKey should be in {accepted_keys}",
        expected=f"in {accepted_keys}",
        actual=f"antiAffinityTopologyKey={topology_key}, found={topo_found}",
        source=path,
    )
    assert topo_found, f"PXC antiAffinityTopologyKey must be one of {accepted_keys}"


@pytest.mark.unit
def test_pxc_anti_affinity_label_selector():
    """Test that PXC anti-affinity uses correct label selector."""
    pytest.skip("Label selector validation not applicable for PerconaXtraDBCluster CR format (operator-managed)")


@pytest.mark.unit
def test_proxysql_anti_affinity_required():
    """Test that ProxySQL/HAProxy has required anti-affinity rules."""
    values, path = get_values_for_test()
    
    # Try proxysql first, then haproxy
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    proxy_affinity = proxy.get('affinity', {})
    
    assert 'antiAffinityTopologyKey' in proxy_affinity, f"{proxy_name} must have affinity.antiAffinityTopologyKey configured"
    
    topology_key = proxy_affinity['antiAffinityTopologyKey']
    log_check(
        criterion=f"{proxy_name} antiAffinityTopologyKey must be set",
        expected="non-empty string",
        actual=f"antiAffinityTopologyKey={topology_key}",
        source=path,
    )
    assert topology_key, f"{proxy_name} must have antiAffinityTopologyKey configured"


@pytest.mark.unit
def test_proxysql_anti_affinity_topology_distribution():
    """Test that ProxySQL/HAProxy anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    # Try proxysql first, then haproxy
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    proxy_affinity = proxy.get('affinity', {})
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']
    
    assert 'antiAffinityTopologyKey' in proxy_affinity, f"{proxy_name} must have affinity.antiAffinityTopologyKey configured"
    
    topology_key = proxy_affinity['antiAffinityTopologyKey']
    topo_found = topology_key in accepted_keys
    log_check(
        criterion=f"{proxy_name} antiAffinityTopologyKey should be in {accepted_keys}",
        expected=f"in {accepted_keys}",
        actual=f"antiAffinityTopologyKey={topology_key}, found={topo_found}",
        source=path,
    )
    assert topo_found, f"{proxy_name} antiAffinityTopologyKey must be one of {accepted_keys}"


@pytest.mark.unit
def test_proxysql_anti_affinity_label_selector():
    """Test that ProxySQL/HAProxy anti-affinity uses correct label selector."""
    pytest.skip("Label selector validation not applicable for PerconaXtraDBCluster CR format (operator-managed)")


@pytest.mark.unit
def test_anti_affinity_prevents_single_host_or_zone_packing():
    """Test that anti-affinity rules prevent all pods from being on same host (on-prem) or same AZ (EKS)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    pxc_affinity = pxc.get('affinity', {})
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    proxy_affinity = proxy.get('affinity', {})
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']
    
    # Check PXC
    assert 'antiAffinityTopologyKey' in pxc_affinity, "PXC must have affinity.antiAffinityTopologyKey configured"
    pxc_has_required = pxc_affinity['antiAffinityTopologyKey'] in accepted_keys
    
    # Check proxy
    assert 'antiAffinityTopologyKey' in proxy_affinity, f"{proxy_name} must have affinity.antiAffinityTopologyKey configured"
    proxy_has_required = proxy_affinity['antiAffinityTopologyKey'] in accepted_keys
    
    log_check(
        criterion=f"Both PXC and {proxy_name} must include required anti-affinity topology",
        expected="both have required topology keys",
        actual=f"pxc_has_required={pxc_has_required}, {proxy_name}_has_required={proxy_has_required}",
        source=path,
    )
    assert pxc_has_required and proxy_has_required, \
        f"Both PXC and {proxy_name} must have required anti-affinity to ensure proper distribution"


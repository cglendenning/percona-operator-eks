"""
Unit tests for anti-affinity rules configuration.
Validates that pods are distributed across availability zones per Percona best practices.
"""
import os
import yaml
import pytest
from conftest import log_check, TOPOLOGY_KEY, get_values_for_test


@pytest.mark.unit
def test_pxc_anti_affinity_required():
    """Test that PXC has required anti-affinity rules."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    affinity = pxc.get('affinity', {})
    
    # EKS uses full podAntiAffinity structure (raw values file format)
    assert 'podAntiAffinity' in affinity, "PXC must have affinity.podAntiAffinity configured"
    pod_anti_affinity = affinity['podAntiAffinity']
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity, "PXC podAntiAffinity must have required rules"
    
    log_check(
        criterion="PXC podAntiAffinity must have required scheduling rules",
        expected="requiredDuringSchedulingIgnoredDuringExecution present",
        actual=f"rules present=True",
        source=path,
    )
    assert len(pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']) > 0, "PXC must have at least one anti-affinity rule"


@pytest.mark.unit
def test_pxc_anti_affinity_topology_distribution():
    """Test that PXC anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    affinity = pxc.get('affinity', {})
    
    # EKS uses full podAntiAffinity structure
    assert 'podAntiAffinity' in affinity, "PXC must have affinity.podAntiAffinity configured"
    pod_anti_affinity = affinity['podAntiAffinity']
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity, "PXC podAntiAffinity must have required rules"
    
    rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
    assert len(rules) > 0, "PXC must have at least one anti-affinity rule"
    
    topology_key = rules[0].get('topologyKey')
    expected_key = TOPOLOGY_KEY  # topology.kubernetes.io/zone for EKS
    
    log_check(
        criterion=f"PXC podAntiAffinity topologyKey should be {expected_key}",
        expected=expected_key,
        actual=f"topologyKey={topology_key}",
        source=path,
    )
    assert topology_key == expected_key, f"PXC topologyKey must be {expected_key}"


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
    
    # EKS uses full podAntiAffinity structure
    assert 'podAntiAffinity' in proxy_affinity, f"{proxy_name} must have affinity.podAntiAffinity configured"
    pod_anti_affinity = proxy_affinity['podAntiAffinity']
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity, f"{proxy_name} podAntiAffinity must have required rules"
    
    log_check(
        criterion=f"{proxy_name} podAntiAffinity must have required scheduling rules",
        expected="requiredDuringSchedulingIgnoredDuringExecution present",
        actual=f"rules present=True",
        source=path,
    )
    assert len(pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']) > 0, f"{proxy_name} must have at least one anti-affinity rule"


@pytest.mark.unit
def test_proxysql_anti_affinity_topology_distribution():
    """Test that ProxySQL/HAProxy anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    # Try proxysql first, then haproxy
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    proxy_affinity = proxy.get('affinity', {})
    
    # EKS uses full podAntiAffinity structure
    assert 'podAntiAffinity' in proxy_affinity, f"{proxy_name} must have affinity.podAntiAffinity configured"
    pod_anti_affinity = proxy_affinity['podAntiAffinity']
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity, f"{proxy_name} podAntiAffinity must have required rules"
    
    rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
    assert len(rules) > 0, f"{proxy_name} must have at least one anti-affinity rule"
    
    topology_key = rules[0].get('topologyKey')
    expected_key = TOPOLOGY_KEY  # topology.kubernetes.io/zone for EKS
    
    log_check(
        criterion=f"{proxy_name} podAntiAffinity topologyKey should be {expected_key}",
        expected=expected_key,
        actual=f"topologyKey={topology_key}",
        source=path,
    )
    assert topology_key == expected_key, f"{proxy_name} topologyKey must be {expected_key}"


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
    
    expected_key = TOPOLOGY_KEY  # topology.kubernetes.io/zone for EKS
    
    # Check PXC - EKS uses full podAntiAffinity structure
    assert 'podAntiAffinity' in pxc_affinity, "PXC must have affinity.podAntiAffinity configured"
    pxc_pod_anti_affinity = pxc_affinity['podAntiAffinity']
    pxc_rules = pxc_pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
    pxc_has_required = len(pxc_rules) > 0 and pxc_rules[0].get('topologyKey') == expected_key
    
    # Check proxy - EKS uses full podAntiAffinity structure
    assert 'podAntiAffinity' in proxy_affinity, f"{proxy_name} must have affinity.podAntiAffinity configured"
    proxy_pod_anti_affinity = proxy_affinity['podAntiAffinity']
    proxy_rules = proxy_pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
    proxy_has_required = len(proxy_rules) > 0 and proxy_rules[0].get('topologyKey') == expected_key
    
    log_check(
        criterion=f"Both PXC and {proxy_name} must include required anti-affinity topology",
        expected="both have required topology keys",
        actual=f"pxc_has_required={pxc_has_required}, {proxy_name}_has_required={proxy_has_required}",
        source=path,
    )
    assert pxc_has_required and proxy_has_required, \
        f"Both PXC and {proxy_name} must have required anti-affinity to ensure proper distribution"


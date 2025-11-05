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
    
    # Check for antiAffinityTopologyKey (PerconaXtraDBCluster CR format from Fleet)
    # OR podAntiAffinity (raw values format)
    if 'antiAffinityTopologyKey' in affinity:
        topology_key = affinity['antiAffinityTopologyKey']
        log_check(
            criterion="PXC antiAffinityTopologyKey must be set",
            expected="non-empty string",
            actual=f"antiAffinityTopologyKey={topology_key}",
            source=path,
        )
        assert topology_key, "PXC must have antiAffinityTopologyKey configured"
    elif 'podAntiAffinity' in affinity:
        pod_anti_affinity = affinity['podAntiAffinity']
        log_check(
            criterion="PXC must have podAntiAffinity configured",
            expected="requiredDuringSchedulingIgnoredDuringExecution present",
            actual=f"podAntiAffinity present with {len(pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', []))} rules",
            source=path,
        )
        assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
        assert len(pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']) > 0
    else:
        pytest.fail("PXC must have either antiAffinityTopologyKey or podAntiAffinity configured")


@pytest.mark.unit
def test_pxc_anti_affinity_topology_distribution():
    """Test that PXC anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    affinity = pxc.get('affinity', {})
    
    # Define accepted topology keys based on environment
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']
    
    # Check Fleet CR format or raw values format
    if 'antiAffinityTopologyKey' in affinity:
        topology_key = affinity['antiAffinityTopologyKey']
        topo_found = topology_key in accepted_keys
        log_check(
            criterion=f"PXC antiAffinityTopologyKey should be in {accepted_keys}",
            expected=f"in {accepted_keys}",
            actual=f"antiAffinityTopologyKey={topology_key}, found={topo_found}",
            source=path,
        )
        assert topo_found, f"PXC antiAffinityTopologyKey must be one of {accepted_keys}"
    elif 'podAntiAffinity' in affinity:
        pod_anti_affinity = affinity['podAntiAffinity']
        required = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
        topology_key = required['topologyKey']
        topo_found = topology_key in accepted_keys
        log_check(
            criterion=f"PXC podAntiAffinity topologyKey should be in {accepted_keys}",
            expected=f"in {accepted_keys}",
            actual=f"topologyKey={topology_key}, found={topo_found}",
            source=path,
        )
        assert topo_found, f"PXC topologyKey must be one of {accepted_keys}"
    else:
        pytest.fail("PXC must have either antiAffinityTopologyKey or podAntiAffinity configured")


@pytest.mark.unit
def test_pxc_anti_affinity_label_selector():
    """Test that PXC anti-affinity uses correct label selector."""
    pytest.skip("Label selector validation not applicable for PerconaXtraDBCluster CR format (operator-managed)")


@pytest.mark.unit
def test_proxysql_anti_affinity_required(request):
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    """Test that ProxySQL has required anti-affinity rules."""
    values, path = get_values_for_test()
    
    # This test only runs with --proxysql, so check ProxySQL
    proxy = values.get('proxysql', {})
    if not proxy.get('enabled'):
        pytest.skip("ProxySQL is not enabled in this configuration")
    
    proxy_name = 'proxysql'
    proxy_affinity = proxy.get('affinity', {})
    
    # Check Fleet CR format or raw values format
    if 'antiAffinityTopologyKey' in proxy_affinity:
        topology_key = proxy_affinity['antiAffinityTopologyKey']
        log_check(
            criterion=f"{proxy_name} antiAffinityTopologyKey must be set",
            expected="non-empty string",
            actual=f"antiAffinityTopologyKey={topology_key}",
            source=path,
        )
        assert topology_key, f"{proxy_name} must have antiAffinityTopologyKey configured"
    elif 'podAntiAffinity' in proxy_affinity:
        pod_anti_affinity = proxy_affinity['podAntiAffinity']
        log_check(
            criterion=f"{proxy_name} must have podAntiAffinity configured",
            expected="requiredDuringSchedulingIgnoredDuringExecution present",
            actual=f"podAntiAffinity present with {len(pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', []))} rules",
            source=path,
        )
        assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
        assert len(pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']) > 0
    else:
        pytest.fail(f"{proxy_name} must have either antiAffinityTopologyKey or podAntiAffinity configured")


@pytest.mark.unit
def test_proxysql_anti_affinity_topology_distribution(request):
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    """Test that ProxySQL anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    # This test only runs with --proxysql, so check ProxySQL
    proxy = values.get('proxysql', {})
    if not proxy.get('enabled'):
        pytest.skip("ProxySQL is not enabled in this configuration")
    
    proxy_name = 'proxysql'
    proxy_affinity = proxy.get('affinity', {})
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']
    
    # Check Fleet CR format or raw values format
    if 'antiAffinityTopologyKey' in proxy_affinity:
        topology_key = proxy_affinity['antiAffinityTopologyKey']
        topo_found = topology_key in accepted_keys
        log_check(
            criterion=f"{proxy_name} antiAffinityTopologyKey should be in {accepted_keys}",
            expected=f"in {accepted_keys}",
            actual=f"antiAffinityTopologyKey={topology_key}, found={topo_found}",
            source=path,
        )
        assert topo_found, f"{proxy_name} antiAffinityTopologyKey must be one of {accepted_keys}"
    elif 'podAntiAffinity' in proxy_affinity:
        pod_anti_affinity = proxy_affinity['podAntiAffinity']
        required = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
        topology_key = required['topologyKey']
        topo_found = topology_key in accepted_keys
        log_check(
            criterion=f"{proxy_name} podAntiAffinity topologyKey should be in {accepted_keys}",
            expected=f"in {accepted_keys}",
            actual=f"topologyKey={topology_key}, found={topo_found}",
            source=path,
        )
        assert topo_found, f"{proxy_name} topologyKey must be one of {accepted_keys}"
    else:
        pytest.fail(f"{proxy_name} must have either antiAffinityTopologyKey or podAntiAffinity configured")


@pytest.mark.unit
def test_proxysql_anti_affinity_label_selector(request):
    if not request.config.getoption('--proxysql'):
        pytest.skip("ProxySQL tests only run with --proxysql flag (on-prem uses HAProxy by default)")
    """Test that ProxySQL/HAProxy anti-affinity uses correct label selector."""
    pytest.skip("Label selector validation not applicable for PerconaXtraDBCluster CR format (operator-managed)")


@pytest.mark.unit
def test_anti_affinity_prevents_single_host_or_zone_packing(request):
    """Test that anti-affinity rules prevent all pods from being on same host (on-prem) or same AZ (EKS)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    pxc_affinity = pxc.get('affinity', {})
    
    # Determine which proxy is enabled (HAProxy by default on on-prem, ProxySQL if --proxysql flag)
    proxysql_enabled = values.get('proxysql', {}).get('enabled', False)
    haproxy_enabled = values.get('haproxy', {}).get('enabled', False)
    
    if proxysql_enabled and request.config.getoption('--proxysql'):
        proxy = values.get('proxysql', {})
        proxy_name = 'proxysql'
    elif haproxy_enabled:
        proxy = values.get('haproxy', {})
        proxy_name = 'haproxy'
    else:
        pytest.skip("No proxy (ProxySQL or HAProxy) is enabled in this configuration")
    
    proxy_affinity = proxy.get('affinity', {})
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']
    
    # Check PXC - Fleet CR format or raw values format
    if 'antiAffinityTopologyKey' in pxc_affinity:
        pxc_has_required = pxc_affinity['antiAffinityTopologyKey'] in accepted_keys
    elif 'podAntiAffinity' in pxc_affinity:
        pod_anti_affinity = pxc_affinity['podAntiAffinity']
        required = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
        pxc_has_required = required['topologyKey'] in accepted_keys
    else:
        pytest.fail("PXC must have either antiAffinityTopologyKey or podAntiAffinity configured")
    
    # Check proxy - Fleet CR format or raw values format
    if 'antiAffinityTopologyKey' in proxy_affinity:
        proxy_has_required = proxy_affinity['antiAffinityTopologyKey'] in accepted_keys
    elif 'podAntiAffinity' in proxy_affinity:
        pod_anti_affinity = proxy_affinity['podAntiAffinity']
        required = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution'][0]
        proxy_has_required = required['topologyKey'] in accepted_keys
    else:
        pytest.fail(f"{proxy_name} must have either antiAffinityTopologyKey or podAntiAffinity configured")
    
    log_check(
        criterion=f"Both PXC and {proxy_name} must include required anti-affinity topology",
        expected="both have required topology keys",
        actual=f"pxc_has_required={pxc_has_required}, {proxy_name}_has_required={proxy_has_required}",
        source=path,
    )
    assert pxc_has_required and proxy_has_required, \
        f"Both PXC and {proxy_name} must have required anti-affinity to ensure proper distribution"


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
    
    # Check for antiAffinityTopologyKey (PerconaXtraDBCluster CR format)
    if 'antiAffinityTopologyKey' in pxc:
        topology_key = pxc['antiAffinityTopologyKey']
        log_check(
            criterion="PXC antiAffinityTopologyKey must be set",
            expected="non-empty string",
            actual=f"antiAffinityTopologyKey={topology_key}",
            source=path,
        )
        assert topology_key, "PXC must have antiAffinityTopologyKey configured"
        return
    
    # Otherwise check for full affinity.podAntiAffinity structure (values file format)
    affinity = pxc.get('affinity', {})
    log_check(
        criterion="PXC affinity must include podAntiAffinity",
        expected="podAntiAffinity present",
        actual=f"keys={sorted(list(affinity.keys()))}",
        source=path,
    )
    assert 'podAntiAffinity' in affinity
    
    pod_anti_affinity = affinity['podAntiAffinity']
    log_check(
        criterion="PXC podAntiAffinity must include requiredDuringSchedulingIgnoredDuringExecution",
        expected="key present",
        actual=f"keys={sorted(list(pod_anti_affinity.keys()))}",
        source=path,
    )
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
    
    required_rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
    log_check(
        criterion="PXC must have at least one required anti-affinity rule",
        expected="> 0",
        actual=f"count={len(required_rules)}",
        source=path,
    )
    assert len(required_rules) > 0, "PXC must have required anti-affinity rules"


@pytest.mark.unit
def test_pxc_anti_affinity_topology_distribution():
    """Test that PXC anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    
    # Define accepted topology keys
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']
    
    # Check for antiAffinityTopologyKey (PerconaXtraDBCluster CR format)
    if 'antiAffinityTopologyKey' in pxc:
        topology_key = pxc['antiAffinityTopologyKey']
        topo_found = topology_key in accepted_keys
        log_check(
            criterion=f"PXC antiAffinityTopologyKey should be in {accepted_keys}",
            expected=f"in {accepted_keys}",
            actual=f"antiAffinityTopologyKey={topology_key}, found={topo_found}",
            source=path,
        )
        assert topo_found, f"PXC antiAffinityTopologyKey must be one of {accepted_keys}"
        return
    
    # Otherwise check full affinity.podAntiAffinity structure
    required_rules = pxc['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Check that at least one rule uses the accepted topology key
    topo_found = False
    for rule in required_rules:
        if rule.get('topologyKey') in accepted_keys:
            topo_found = True
            break
    
    log_check(
        criterion="At least one PXC anti-affinity rule uses required topology key",
        expected=f"topologyKey in {accepted_keys}",
        actual=f"found={topo_found}",
        source=path,
    )
    assert topo_found, "PXC anti-affinity must use the required topology key for distribution"


@pytest.mark.unit
def test_pxc_anti_affinity_label_selector():
    """Test that PXC anti-affinity uses correct label selector."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    
    # Skip if using PerconaXtraDBCluster CR format (operator generates label selectors)
    if 'antiAffinityTopologyKey' in pxc:
        pytest.skip("Label selector validation not applicable for PerconaXtraDBCluster CR format (operator-managed)")
    
    required_rules = pxc['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Find rule with required topology
    for rule in required_rules:
        if rule.get('topologyKey') in (['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']):
            label_selector = rule.get('labelSelector', {})
            match_expressions = label_selector.get('matchExpressions', [])
            
            # Should match PXC component
            pxc_expression_found = False
            for expr in match_expressions:
                if (expr.get('key') == 'app.kubernetes.io/component' and
                    expr.get('operator') == 'In' and
                    'pxc' in expr.get('values', [])):
                    pxc_expression_found = True
                    break
            
            log_check(
                criterion="PXC anti-affinity label selector must match component=pxc",
                expected="matchExpressions includes app.kubernetes.io/component In [pxc]",
                actual=f"found={pxc_expression_found}",
                source=path,
            )
            assert pxc_expression_found, "PXC anti-affinity must match app.kubernetes.io/component=pxc"
            break


@pytest.mark.unit
def test_proxysql_anti_affinity_required():
    """Test that ProxySQL/HAProxy has required anti-affinity rules."""
    values, path = get_values_for_test()
    
    # Try proxysql first, then haproxy
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    
    # Check for antiAffinityTopologyKey (PerconaXtraDBCluster CR format)
    if 'antiAffinityTopologyKey' in proxy:
        topology_key = proxy['antiAffinityTopologyKey']
        log_check(
            criterion=f"{proxy_name} antiAffinityTopologyKey must be set",
            expected="non-empty string",
            actual=f"antiAffinityTopologyKey={topology_key}",
            source=path,
        )
        assert topology_key, f"{proxy_name} must have antiAffinityTopologyKey configured"
        return
    
    # Otherwise check for full affinity.podAntiAffinity structure
    affinity = proxy.get('affinity', {})
    log_check(
        criterion=f"{proxy_name} affinity must include podAntiAffinity",
        expected="podAntiAffinity present",
        actual=f"keys={sorted(list(affinity.keys()))}",
        source=path,
    )
    assert 'podAntiAffinity' in affinity
    
    pod_anti_affinity = affinity['podAntiAffinity']
    log_check(
        criterion=f"{proxy_name} podAntiAffinity must include requiredDuringSchedulingIgnoredDuringExecution",
        expected="key present",
        actual=f"keys={sorted(list(pod_anti_affinity.keys()))}",
        source=path,
    )
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
    
    required_rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
    log_check(
        criterion=f"{proxy_name} must have at least one required anti-affinity rule",
        expected="> 0",
        actual=f"count={len(required_rules)}",
        source=path,
    )
    assert len(required_rules) > 0, f"{proxy_name} must have required anti-affinity rules"


@pytest.mark.unit
def test_proxysql_anti_affinity_topology_distribution():
    """Test that ProxySQL/HAProxy anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    values, path = get_values_for_test()
    
    # Try proxysql first, then haproxy
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']
    
    # Check for antiAffinityTopologyKey (PerconaXtraDBCluster CR format)
    if 'antiAffinityTopologyKey' in proxy:
        topology_key = proxy['antiAffinityTopologyKey']
        topo_found = topology_key in accepted_keys
        log_check(
            criterion=f"{proxy_name} antiAffinityTopologyKey should be in {accepted_keys}",
            expected=f"in {accepted_keys}",
            actual=f"antiAffinityTopologyKey={topology_key}, found={topo_found}",
            source=path,
        )
        assert topo_found, f"{proxy_name} antiAffinityTopologyKey must be one of {accepted_keys}"
        return
    
    # Otherwise check full affinity.podAntiAffinity structure
    required_rules = proxy['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']

    topo_found = False
    for rule in required_rules:
        if rule.get('topologyKey') in accepted_keys:
            topo_found = True
            break
    
    log_check(
        criterion=f"At least one {proxy_name} anti-affinity rule uses required topology key",
        expected=f"topologyKey in {accepted_keys}",
        actual=f"found={topo_found}",
        source=path,
    )
    assert topo_found, f"{proxy_name} anti-affinity must use the required topology key for distribution"


@pytest.mark.unit
def test_proxysql_anti_affinity_label_selector():
    """Test that ProxySQL/HAProxy anti-affinity uses correct label selector."""
    values, path = get_values_for_test()
    
    # Try proxysql first, then haproxy
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    
    # Skip if using PerconaXtraDBCluster CR format (operator generates label selectors)
    if 'antiAffinityTopologyKey' in proxy:
        pytest.skip("Label selector validation not applicable for PerconaXtraDBCluster CR format (operator-managed)")
    
    required_rules = proxy['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Find rule with required topology
    for rule in required_rules:
        if rule.get('topologyKey') in (['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']):
            label_selector = rule.get('labelSelector', {})
            match_expressions = label_selector.get('matchExpressions', [])
            
            # Should match proxy component
            proxy_expression_found = False
            for expr in match_expressions:
                if (expr.get('key') == 'app.kubernetes.io/component' and
                    expr.get('operator') == 'In' and
                    proxy_name in expr.get('values', [])):
                    proxy_expression_found = True
                    break
            
            log_check(
                criterion=f"{proxy_name} anti-affinity label selector must match component={proxy_name}",
                expected=f"matchExpressions includes app.kubernetes.io/component In [{proxy_name}]",
                actual=f"found={proxy_expression_found}",
                source=path,
            )
            assert proxy_expression_found, f"{proxy_name} anti-affinity must match app.kubernetes.io/component={proxy_name}"
            break


@pytest.mark.unit
def test_anti_affinity_prevents_single_host_or_zone_packing():
    """Test that anti-affinity rules prevent all pods from being on same host (on-prem) or same AZ (EKS)."""
    values, path = get_values_for_test()
    
    pxc = values.get('pxc', {})
    proxy = values.get('proxysql') or values.get('haproxy', {})
    proxy_name = 'proxysql' if 'proxysql' in values else 'haproxy'
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']
    
    # Check PXC
    if 'antiAffinityTopologyKey' in pxc:
        pxc_has_required = pxc['antiAffinityTopologyKey'] in accepted_keys
    else:
        pxc_has_required = any(
            rule.get('topologyKey') in accepted_keys
            for rule in pxc['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
        )
    
    # Check proxy
    if 'antiAffinityTopologyKey' in proxy:
        proxy_has_required = proxy['antiAffinityTopologyKey'] in accepted_keys
    else:
        proxy_has_required = any(
            rule.get('topologyKey') in accepted_keys
            for rule in proxy['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
        )
    
    log_check(
        criterion=f"Both PXC and {proxy_name} must include required anti-affinity topology",
        expected="both have required topology keys",
        actual=f"pxc_has_required={pxc_has_required}, {proxy_name}_has_required={proxy_has_required}",
        source=path,
    )
    assert pxc_has_required and proxy_has_required, \
        f"Both PXC and {proxy_name} must have required anti-affinity to ensure proper distribution"


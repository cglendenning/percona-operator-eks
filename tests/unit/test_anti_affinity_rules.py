"""
Unit tests for anti-affinity rules configuration.
Validates that pods are distributed across availability zones per Percona best practices.
"""
import os
import yaml
import pytest
from tests.conftest import log_check, TOPOLOGY_KEY


@pytest.mark.unit
def test_pxc_anti_affinity_required():
    """Test that PXC has required anti-affinity rules."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    affinity = values['pxc']['affinity']
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
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Define accepted topology keys
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']

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
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
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
    """Test that ProxySQL has required anti-affinity rules."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    affinity = values['proxysql']['affinity']
    log_check(
        criterion="ProxySQL affinity must include podAntiAffinity",
        expected="podAntiAffinity present",
        actual=f"keys={sorted(list(affinity.keys()))}",
        source=path,
    )
    assert 'podAntiAffinity' in affinity
    
    pod_anti_affinity = affinity['podAntiAffinity']
    log_check(
        criterion="ProxySQL podAntiAffinity must include requiredDuringSchedulingIgnoredDuringExecution",
        expected="key present",
        actual=f"keys={sorted(list(pod_anti_affinity.keys()))}",
        source=path,
    )
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
    
    required_rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
    log_check(
        criterion="ProxySQL must have at least one required anti-affinity rule",
        expected="> 0",
        actual=f"count={len(required_rules)}",
        source=path,
    )
    assert len(required_rules) > 0, "ProxySQL must have required anti-affinity rules"


@pytest.mark.unit
def test_proxysql_anti_affinity_topology_distribution():
    """Test that ProxySQL anti-affinity uses the correct topology key (zone on EKS, hostname on on-prem)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
    if TOPOLOGY_KEY == 'kubernetes.io/hostname':
        accepted_keys = ['kubernetes.io/hostname']

    topo_found = False
    for rule in required_rules:
        if rule.get('topologyKey') in accepted_keys:
            topo_found = True
            break
    
    log_check(
        criterion="At least one ProxySQL anti-affinity rule uses required topology key",
        expected=f"topologyKey in {accepted_keys}",
        actual=f"found={topo_found}",
        source=path,
    )
    assert topo_found, "ProxySQL anti-affinity must use the required topology key for distribution"


@pytest.mark.unit
def test_proxysql_anti_affinity_label_selector():
    """Test that ProxySQL anti-affinity uses correct label selector."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Find rule with required topology
    for rule in required_rules:
        if rule.get('topologyKey') in (['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']):
            label_selector = rule.get('labelSelector', {})
            match_expressions = label_selector.get('matchExpressions', [])
            
            # Should match ProxySQL component
            proxysql_expression_found = False
            for expr in match_expressions:
                if (expr.get('key') == 'app.kubernetes.io/component' and
                    expr.get('operator') == 'In' and
                    'proxysql' in expr.get('values', [])):
                    proxysql_expression_found = True
                    break
            
            log_check(
                criterion="ProxySQL anti-affinity label selector must match component=proxysql",
                expected="matchExpressions includes app.kubernetes.io/component In [proxysql]",
                actual=f"found={proxysql_expression_found}",
                source=path,
            )
            assert proxysql_expression_found, "ProxySQL anti-affinity must match app.kubernetes.io/component=proxysql"
            break


@pytest.mark.unit
def test_anti_affinity_prevents_single_host_or_zone_packing():
    """Test that anti-affinity rules prevent all pods from being on same host (on-prem) or same AZ (EKS)."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # Both PXC and ProxySQL should have required anti-affinity
    accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'] if TOPOLOGY_KEY != 'kubernetes.io/hostname' else ['kubernetes.io/hostname']
    pxc_has_required = any(
        rule.get('topologyKey') in accepted_keys
        for rule in values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    )
    
    proxysql_has_required = any(
        rule.get('topologyKey') in accepted_keys
        for rule in values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    )
    
    log_check(
        criterion="Both PXC and ProxySQL must include required anti-affinity topology",
        expected=f"topologyKey in {accepted_keys}",
        actual=f"pxc_has_required={pxc_has_required}, proxysql_has_required={proxysql_has_required}",
        source=path,
    )
    assert pxc_has_required and proxysql_has_required, \
        "Both PXC and ProxySQL must have required anti-affinity to ensure proper distribution"


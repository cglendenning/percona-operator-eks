"""
Unit tests for anti-affinity rules configuration.
Validates that pods are distributed across availability zones per Percona best practices.
"""
import os
import yaml
import pytest
from tests.conftest import log_check


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
def test_pxc_anti_affinity_zone_distribution():
    """Test that PXC anti-affinity uses zone topology key."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Check that at least one rule uses zone topology key
    zone_topology_found = False
    for rule in required_rules:
        if rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']:
            zone_topology_found = True
            break
    
    log_check(
        criterion="At least one PXC anti-affinity rule uses zone topology key",
        expected="topologyKey in [zone keys]",
        actual=f"found={zone_topology_found}",
        source=path,
    )
    assert zone_topology_found, "PXC anti-affinity must use zone topology key for multi-AZ distribution"


@pytest.mark.unit
def test_pxc_anti_affinity_label_selector():
    """Test that PXC anti-affinity uses correct label selector."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Find rule with zone topology
    for rule in required_rules:
        if rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']:
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
def test_proxysql_anti_affinity_zone_distribution():
    """Test that ProxySQL anti-affinity uses zone topology key."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Check that at least one rule uses zone topology key
    zone_topology_found = False
    for rule in required_rules:
        if rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']:
            zone_topology_found = True
            break
    
    log_check(
        criterion="At least one ProxySQL anti-affinity rule uses zone topology key",
        expected="topologyKey in [zone keys]",
        actual=f"found={zone_topology_found}",
        source=path,
    )
    assert zone_topology_found, "ProxySQL anti-affinity must use zone topology key for multi-AZ distribution"


@pytest.mark.unit
def test_proxysql_anti_affinity_label_selector():
    """Test that ProxySQL anti-affinity uses correct label selector."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    required_rules = values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    
    # Find rule with zone topology
    for rule in required_rules:
        if rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']:
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
def test_anti_affinity_prevents_single_az_deployment():
    """Test that anti-affinity rules prevent all pods from being in same AZ."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    # Both PXC and ProxySQL should have zone-based anti-affinity
    pxc_has_zone = any(
        rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
        for rule in values['pxc']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    )
    
    proxysql_has_zone = any(
        rule.get('topologyKey') in ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
        for rule in values['proxysql']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
    )
    
    log_check(
        criterion="Both PXC and ProxySQL must include zone-based anti-affinity",
        expected="pxc_has_zone=True and proxysql_has_zone=True",
        actual=f"pxc_has_zone={pxc_has_zone}, proxysql_has_zone={proxysql_has_zone}",
        source=path,
    )
    assert pxc_has_zone and proxysql_has_zone, \
        "Both PXC and ProxySQL must have zone-based anti-affinity to ensure multi-AZ deployment"


"""
Unit tests for anti-affinity rules configuration.
Validates that pods are distributed across availability zones per Percona best practices.
"""
import os
import yaml
import pytest


@pytest.mark.unit
def test_pxc_anti_affinity_required():
    """Test that PXC has required anti-affinity rules."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        content = content.replace('{{NODES}}', '3')
        values = yaml.safe_load(content)
    
    affinity = values['pxc']['affinity']
    assert 'podAntiAffinity' in affinity
    
    pod_anti_affinity = affinity['podAntiAffinity']
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
    
    required_rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
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
    assert 'podAntiAffinity' in affinity
    
    pod_anti_affinity = affinity['podAntiAffinity']
    assert 'requiredDuringSchedulingIgnoredDuringExecution' in pod_anti_affinity
    
    required_rules = pod_anti_affinity['requiredDuringSchedulingIgnoredDuringExecution']
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
    
    assert pxc_has_zone and proxysql_has_zone, \
        "Both PXC and ProxySQL must have zone-based anti-affinity to ensure multi-AZ deployment"


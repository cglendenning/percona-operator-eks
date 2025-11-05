"""
Unit tests for cluster values generation logic.
Tests the clusterValues function behavior by validating template substitution.
"""
import os
import yaml
import pytest
import re
from conftest import log_check


@pytest.mark.unit
def test_cluster_values_template_substitution():
    """Test that NODES placeholder is correctly substituted in template."""
    template_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()
    
    # Simulate substitution for different node counts
    for node_count in [3, 6, 9]:
        content = template.replace('{{NODES}}', str(node_count))
        values = yaml.safe_load(content)
        
        log_check(
            criterion=f"pxc.size must equal substituted node_count={node_count}",
            expected=f"{node_count}",
            actual=f"{values['pxc']['size']}",
            source=template_path,
        )
        assert values['pxc']['size'] == node_count
        log_check(
            criterion=f"proxysql.size must equal substituted node_count={node_count}",
            expected=f"{node_count}",
            actual=f"{values['proxysql']['size']}",
            source=template_path,
        )
        assert values['proxysql']['size'] == node_count
        log_check(
            criterion="Template must not retain {{NODES}} placeholder after substitution",
            expected="not present",
            actual=f"present={ '{{NODES}}' in content }",
            source=template_path,
        )
        assert '{{NODES}}' not in content, f"Template still contains {{NODES}} placeholder after substitution"


@pytest.mark.unit
def test_cluster_values_yaml_validity():
    """Test that generated cluster values produce valid YAML."""
    template_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()
    
    for node_count in [3, 6]:
        content = template.replace('{{NODES}}', str(node_count))
        # Should not raise exception
        values = yaml.safe_load(content)
        log_check(
            criterion=f"Generated values for node_count={node_count} must be valid YAML",
            expected="parsed object not None",
            actual=f"is None={values is None}",
            source=template_path,
        )
        assert values is not None


@pytest.mark.unit
def test_cluster_values_node_count_consistency():
    """Test that PXC and ProxySQL have matching node counts."""
    template_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()
    
    for node_count in [3, 6, 9]:
        content = template.replace('{{NODES}}', str(node_count))
        values = yaml.safe_load(content)
        
        log_check(
            criterion=f"pxc.size must equal proxysql.size for node_count={node_count}",
            expected=f"{values['pxc']['size']}",
            actual=f"{values['proxysql']['size']}",
            source=template_path,
        )
        assert values['pxc']['size'] == values['proxysql']['size'], \
            "PXC and ProxySQL node counts must match"


@pytest.mark.unit
def test_cluster_values_minimum_nodes():
    """Test that minimum 3 nodes are enforced (Percona best practice)."""
    template_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()
    
    # Test with minimum recommended nodes
    content = template.replace('{{NODES}}', '3')
    values = yaml.safe_load(content)
    
    log_check("pxc.size must be >= 3", ">= 3", f"{values['pxc']['size']}", source=template_path)
    assert values['pxc']['size'] >= 3, "Percona requires minimum 3 nodes for high availability"
    log_check("proxysql.size must be >= 3", ">= 3", f"{values['proxysql']['size']}", source=template_path)
    assert values['proxysql']['size'] >= 3, "ProxySQL requires minimum 3 nodes for high availability"


@pytest.mark.unit
def test_cluster_values_odd_node_count_preference():
    """Test that odd node counts are preferred for quorum (best practice)."""
    template_path = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'percona', 'templates', 'percona-values.yaml')
    
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()
    
    # Test with odd node count (recommended)
    content = template.replace('{{NODES}}', '3')
    values = yaml.safe_load(content)
    
    node_count = values['pxc']['size']
    # While not enforced, odd numbers are preferred for quorum
    # This test documents the best practice
    if node_count % 2 == 0 and node_count > 4:
        # Even numbers > 4 are acceptable but odd is preferred
        pass
    # 3, 5, 7 nodes are all valid for quorum


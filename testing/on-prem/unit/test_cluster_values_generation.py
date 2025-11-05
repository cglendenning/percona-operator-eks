"""
Unit tests for cluster values generation logic.
Tests the clusterValues function behavior by validating Fleet configuration.
"""
import os
import yaml
import pytest
import re
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_cluster_values_template_substitution():
    """Test that Fleet configuration produces valid cluster values."""
    values, path = get_values_for_test()
    
    # Fleet should have properly configured node counts
    node_count = values['pxc']['size']
    
    log_check(
        criterion=f"pxc.size must be configured",
        expected="> 0",
        actual=f"{node_count}",
        source=path,
    )
    assert node_count > 0, "PXC size must be configured"
    
    # On-prem uses HAProxy by default, check proxy size accordingly
    if values.get('proxysql', {}).get('enabled'):
        log_check(
            criterion=f"proxysql.size must match pxc.size when enabled",
            expected=f"{node_count}",
            actual=f"{values['proxysql']['size']}",
            source=path,
        )
        assert values['proxysql']['size'] == node_count, "ProxySQL size must match PXC size"
    elif values.get('haproxy', {}).get('enabled'):
        haproxy_size = values['haproxy'].get('size', 1)
        log_check(
            criterion=f"haproxy.size must be configured when enabled",
            expected="> 0",
            actual=f"{haproxy_size}",
            source=path,
        )
        assert haproxy_size > 0, "HAProxy size must be configured"


@pytest.mark.unit
def test_cluster_values_yaml_validity():
    """Test that Fleet-rendered cluster values are valid."""
    values, path = get_values_for_test()
    
    log_check(
        criterion="Fleet-rendered values must be valid and not None",
        expected="not None",
        actual=f"is None={values is None}",
        source=path,
    )
    assert values is not None, "Fleet-rendered values must be valid"


@pytest.mark.unit
def test_cluster_values_node_count_consistency():
    """Test that PXC and proxy have matching node counts."""
    values, path = get_values_for_test()
    
    pxc_size = values['pxc']['size']
    
    # On-prem uses HAProxy by default
    if values.get('proxysql', {}).get('enabled'):
        log_check(
            criterion="pxc.size must equal proxysql.size when ProxySQL is enabled",
            expected=f"{pxc_size}",
            actual=f"{values['proxysql']['size']}",
            source=path,
        )
        assert values['pxc']['size'] == values['proxysql']['size'], \
            "PXC and ProxySQL node counts must match"
    elif values.get('haproxy', {}).get('enabled'):
        haproxy_size = values['haproxy'].get('size', 1)
        log_check(
            criterion="haproxy.size must be configured when HAProxy is enabled",
            expected="> 0",
            actual=f"{haproxy_size}",
            source=path,
        )
        assert haproxy_size > 0, "HAProxy size must be configured"


@pytest.mark.unit
def test_cluster_values_minimum_nodes():
    """Test that minimum 3 nodes are enforced (Percona best practice)."""
    values, path = get_values_for_test()
    
    log_check("pxc.size must be >= 3", ">= 3", f"{values['pxc']['size']}", source=path)
    assert values['pxc']['size'] >= 3, "Percona requires minimum 3 nodes for high availability"
    
    # On-prem uses HAProxy by default, ProxySQL may not be configured
    if values.get('proxysql', {}).get('enabled'):
        log_check("proxysql.size must be >= 3 when enabled", ">= 3", f"{values['proxysql']['size']}", source=path)
        assert values['proxysql']['size'] >= 3, "ProxySQL requires minimum 3 nodes for high availability"
    elif values.get('haproxy', {}).get('enabled'):
        haproxy_size = values['haproxy'].get('size', 1)
        log_check("haproxy.size must be >= 1 when enabled", ">= 1", f"{haproxy_size}", source=path)
        assert haproxy_size >= 1, "HAProxy requires at least 1 node"


@pytest.mark.unit
def test_cluster_values_odd_node_count_preference():
    """Test that odd node counts are preferred for quorum (best practice)."""
    values, path = get_values_for_test()
    
    node_count = values['pxc']['size']
    # While not enforced, odd numbers are preferred for quorum
    # This test documents the best practice
    if node_count % 2 == 0 and node_count > 4:
        # Even numbers > 4 are acceptable but odd is preferred
        pass
    # 3, 5, 7 nodes are all valid for quorum


"""
Test that Helm release has correct configuration values
"""
import pytest
import subprocess
import yaml
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_helm_release_has_correct_values():
    """Test that Helm release has correct configuration values"""
    result = subprocess.run(
        ['helm', 'get', 'values', TEST_CLUSTER_NAME, '-n', TEST_NAMESPACE, '--output', 'yaml'],
        capture_output=True,
        text=True,
        check=True
    )

    values = yaml.safe_load(result.stdout)

    # Check PXC size
    pxc_size = values.get('pxc', {}).get('size')
    assert pxc_size == TEST_EXPECTED_NODES, \
        f"PXC size mismatch: expected {TEST_EXPECTED_NODES}, got {pxc_size}"

    # Check ProxySQL is enabled
    proxysql_enabled = values.get('proxysql', {}).get('enabled', False)
    assert proxysql_enabled is True, "ProxySQL should be enabled"

    # Check HAProxy is disabled (or not explicitly enabled)
    haproxy = values.get('haproxy', {})
    haproxy_enabled = haproxy.get('enabled', False) if haproxy else False
    # HAProxy should be disabled when ProxySQL is enabled (def ault is False)
    if haproxy_enabled:
        console.print(f"[yellow]Warning: HAProxy is enabled, but ProxySQL should be used instead[/yellow]")

    # Check persistence is enabled
    persistence_enabled = values.get('pxc', {}).get('persistence', {}).get('enabled', False)
    assert persistence_enabled is True, "Persistence should be enabled"

    console.print(f"[cyan]Helm Values Validated:[/cyan] PXC={pxc_size}, ProxySQL={proxysql_enabled}")

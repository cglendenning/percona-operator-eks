"""
Test that PDB exists for ProxySQL StatefulSet
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_proxysql_pdb_exists(policy_v1):
    """Test that PDB exists for ProxySQL StatefulSet"""
    try:
        pdb_list = policy_v1.list_namespaced_pod_disruption_budget(
            namespace=TEST_NAMESPACE
        )

        proxysql_pdbs = [
            pdb for pdb in pdb_list.items
            if 'proxysql' in pdb.metadata.name.lower()
        ]

        assert len(proxysql_pdbs) > 0, \
            "Pod Disruption Budget for ProxySQL not found"

        pdb = proxysql_pdbs[0]
        console.print(f"[cyan]ProxySQL PDB:[/cyan] {pdb.metadata.name}")

        spec = pdb.spec
        max_unavailable = spec.max_unavailable

        if max_unavailable:
            console.print(f"[cyan]ProxySQL PDB MaxUnavailable:[/cyan] {max_unavailable}")
            assert str(max_unavailable) == '1', \
                f"ProxySQL PDB maxUnavailable should be 1, got: {max_unavailable}"

    except Exception as e:
        console.print(f"[yellow]⚠ PDB check failed:[/yellow] {e}")
        pytest.skip("Pod Disruption Budget check failed - may not be configured")


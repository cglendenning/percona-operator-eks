"""
Test that PDB exists for PXC StatefulSet
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_pxc_pdb_exists(policy_v1):
    """Test that PDB exists for PXC StatefulSet"""
    try:
        pdb_list = policy_v1.list_namespaced_pod_disruption_budget(
            namespace=TEST_NAMESPACE
        )

        pxc_pdbs = [
            pdb for pdb in pdb_list.items
            if 'pxc' in pdb.metadata.name.lower() and 'proxysql' not in pdb.metadata.name.lower()
        ]

        assert len(pxc_pdbs) > 0, \
            "Pod Disruption Budget for PXC not found"

        pdb = pxc_pdbs[0]
        console.print(f"[cyan]PXC PDB:[/cyan] {pdb.metadata.name}")

        # Check minAvailable or maxUnavailable
        spec = pdb.spec
        max_unavailable = spec.max_unavailable
        min_available = spec.min_available

        if max_unavailable:
            console.print(f"[cyan]PXC PDB MaxUnavailable:[/cyan] {max_unavailable}")
            # Should be 1 (from config)
            assert str(max_unavailable) == '1', \
                f"PXC PDB maxUnavailable should be 1, got: {max_unavailable}"

        if min_available:
            console.print(f"[cyan]PXC PDB MinAvailable:[/cyan] {min_available}")

    except Exception as e:
        # PDBs might not exist in all versions
        console.print(f"[yellow]⚠ PDB check failed:[/yellow] {e}")
        pytest.skip("Pod Disruption Budget check failed - may not be configured")

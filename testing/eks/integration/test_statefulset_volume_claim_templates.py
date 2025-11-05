"""
Test that StatefulSets have volume claim templates
"""
import pytest
from kubernetes import client
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from rich.console import Console

console = Console()

@pytest.mark.integration
def test_statefulset_volume_claim_templates(apps_v1):
    """Test that StatefulSets have volume claim templates"""
    # Get all StatefulSets and find PXC by name pattern
    sts_list = apps_v1.list_namespaced_stateful_set(namespace=TEST_NAMESPACE)
    pxc_sts = [sts for sts in sts_list.items if '-pxc' in sts.metadata.name and 'proxysql' not in sts.metadata.name]

    assert len(pxc_sts) > 0, "PXC StatefulSet not found"

    sts = pxc_sts[0]
    volume_claims = sts.spec.volume_claim_templates

    assert len(volume_claims) > 0, \
        "PXC StatefulSet should have volume claim templates"

    for vct in volume_claims:
        console.print(f"[cyan]VolumeClaimTemplate:[/cyan] {vct.metadata.name}")
        assert vct.spec.resources.requests.get('storage') is not None, \
            f"VolumeClaimTemplate {vct.metadata.name} has no storage request"


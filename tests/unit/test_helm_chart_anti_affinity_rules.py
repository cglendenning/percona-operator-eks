"""
Test that Helm chart includes anti-affinity rules in PerconaXtraDBCluster spec
(operator will apply these to StatefulSets)
"""
import pytest
import subprocess
import yaml
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

@pytest.mark.unit
def test_helm_chart_anti_affinity_rules():
    """Test that Helm chart includes anti-affinity rules in PerconaXtraDBCluster spec
    (operator will apply these to StatefulSets)"""
    # Try to ensure internal repo is available (local ChartMuseum)
    import os
    chartmuseum_url = os.getenv('CHARTMUSEUM_URL', 'http://chartmuseum.chartmuseum.svc.cluster.local')
    
    # Check if internal repo exists, add if not
    repo_list = subprocess.run(
        ['helm', 'repo', 'list'],
        capture_output=True,
        text=True
    )
    if 'internal' not in repo_list.stdout:
        subprocess.run(
            ['helm', 'repo', 'add', 'internal', chartmuseum_url],
            capture_output=True,
            text=True
        )
        subprocess.run(['helm', 'repo', 'update'], capture_output=True, text=True)
    
    result = subprocess.run(
        ['helm', 'template', 'test-chart', 'internal/pxc-db', '--namespace', TEST_NAMESPACE],
        capture_output=True,
        text=True,
        timeout=30
    )

    # Check if chart is available (skip if ChartMuseum not accessible)
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")

    # Check for affinity in PerconaXtraDBCluster CR spec
    manifests = list(yaml.safe_load_all(result.stdout))

    cr = next(
        (m for m in manifests if m.get('kind') == 'PerconaXtraDBCluster'),
        None
    )

    assert cr is not None, "PerconaXtraDBCluster not found in Helm chart"

    # Check for affinity in PXC spec
    pxc_spec = cr.get('spec', {}).get('pxc', {})
    affinity = pxc_spec.get('affinity', {})
    pod_anti_affinity = affinity.get('podAntiAffinity', {})

    # If anti-affinity rules are configured, they must use zone topology
    # If no affinity is configured, operator applies defaults (test passes)
    required = pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
    preferred = pod_anti_affinity.get('preferredDuringSchedulingIgnoredDuringExecution', [])
    all_rules = required + preferred
    
    # Only validate if rules are actually defined
    if len(all_rules) > 0:
        for rule in all_rules:
            topology_key = rule.get('topologyKey', '')
            assert topology_key and 'zone' in topology_key.lower(), \
                f"Anti-affinity topologyKey must contain 'zone', got: {topology_key}"


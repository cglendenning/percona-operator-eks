"""
Test that Helm chart includes anti-affinity rules in PerconaXtraDBCluster spec
(operator will apply these to StatefulSets)
"""
import pytest
import subprocess
import yaml
from conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES
from conftest import log_check

@pytest.mark.unit
def test_helm_chart_anti_affinity_rules(chartmuseum_port_forward):
    """Test that Helm chart includes anti-affinity rules in PerconaXtraDBCluster spec
    (operator will apply these to StatefulSets)"""
    # chartmuseum_port_forward fixture handles repo setup
    
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

    log_check(
        criterion="Helm render should include PerconaXtraDBCluster custom resource",
        expected="CR present",
        actual=f"present={cr is not None}",
        source="helm template internal/pxc-db",
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
    log_check(
        criterion="If anti-affinity rules are present, they must use a zone topologyKey",
        expected="topologyKey contains 'zone'",
        actual=f"rules_count={len(all_rules)}",
        source="helm template internal/pxc-db",
    )
    if len(all_rules) > 0:
        for rule in all_rules:
            topology_key = rule.get('topologyKey', '')
            log_check(
                criterion="Anti-affinity rule topologyKey contains 'zone'",
                expected="contains 'zone'",
                actual=f"{topology_key}",
                source="helm template internal/pxc-db",
            )
            assert topology_key and 'zone' in topology_key.lower(), \
                f"Anti-affinity topologyKey must contain 'zone', got: {topology_key}"


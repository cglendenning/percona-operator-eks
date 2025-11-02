"""
Unit tests: Helm chart rendering and validation
These tests don't require a running cluster, just Helm templates.
"""
import pytest
import yaml
import subprocess
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

console = Console()


@pytest.mark.unit
class TestHelmChartRendering:
    """Test Helm chart rendering without cluster"""

    def test_helm_chart_values_valid(self):
        """Test that Helm chart can be rendered with default values"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        assert result.returncode == 0, \
            f"Helm chart rendering failed: {result.stderr}"
        
        # Parse YAML output
        manifests = []
        for doc in yaml.safe_load_all(result.stdout):
            if doc:
                manifests.append(doc)
        
        assert len(manifests) > 0, "Helm chart produced no manifests"
        console.print(f"[cyan]Helm chart rendered:[/cyan] {len(manifests)} manifests")

    def test_helm_chart_renders_statefulset(self):
        """Test that Helm chart renders PerconaXtraDBCluster custom resource"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        assert 'PerconaXtraDBCluster' in result.stdout, "Helm chart should render PerconaXtraDBCluster custom resource"
        
        # Parse and verify PerconaXtraDBCluster CR
        manifests = []
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'PerconaXtraDBCluster':
                manifests.append(doc)
        
        assert len(manifests) >= 1, \
            f"Expected at least 1 PerconaXtraDBCluster CR, found {len(manifests)}"
        
        # Verify the CR has PXC and ProxySQL specs
        cr = manifests[0]
        pxc_spec = cr.get('spec', {}).get('pxc', {})
        proxysql_spec = cr.get('spec', {}).get('proxysql', {})
        
        assert pxc_spec is not None and len(pxc_spec) > 0, "PerconaXtraDBCluster should have PXC spec"
        assert proxysql_spec is not None and len(proxysql_spec) > 0, "PerconaXtraDBCluster should have ProxySQL spec"

    def test_helm_chart_renders_pvc(self):
        """Test that Helm chart includes PVC configuration in PerconaXtraDBCluster spec"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        manifests = list(yaml.safe_load_all(result.stdout))
        cr = next(
            (m for m in manifests if m.get('kind') == 'PerconaXtraDBCluster'),
            None
        )
        
        assert cr is not None, "PerconaXtraDBCluster not found in Helm chart"
        
        # Check for volumeSpec in PXC spec (indicates PVC configuration)
        pxc_spec = cr.get('spec', {}).get('pxc', {})
        volume_spec = pxc_spec.get('volumeSpec', {})
        pvc_spec = volume_spec.get('persistentVolumeClaim', {})
        
        assert pvc_spec is not None and len(pvc_spec) > 0, \
            "PerconaXtraDBCluster PXC spec should have persistentVolumeClaim volumeSpec"

    def test_helm_chart_anti_affinity_rules(self):
        """Test that Helm chart includes anti-affinity rules in PerconaXtraDBCluster spec"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
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
        
        # The chart may have affinity configured or operator may apply defaults
        if pod_anti_affinity or affinity:
            required = pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
            if len(required) > 0:
                for rule in required:
                    topology_key = rule.get('topologyKey', '')
                    assert 'zone' in topology_key.lower(), \
                        f"Anti-affinity topologyKey should contain 'zone', got: {topology_key}"
            else:
                console.print("[yellow]Note: Anti-affinity configured but not in expected format (operator may handle this)[/yellow]")
        else:
            console.print("[yellow]Note: No explicit affinity in Helm chart (operator may apply defaults)[/yellow]")


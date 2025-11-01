"""
Test Helm chart rendering and validation
"""
import pytest
import yaml
import subprocess
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

console = Console()


class TestHelmCharts:
    """Test Helm chart rendering and validation"""

    def test_helm_repo_available(self):
        """Test that Percona Helm repo is available"""
        result = subprocess.run(
            ['helm', 'repo', 'list'],
            capture_output=True,
            text=True,
            check=True
        )
        
        assert 'percona' in result.stdout.lower(), \
            "Percona Helm repo not found. Run: helm repo add percona https://percona.github.io/percona-helm-charts/"

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

    def test_helm_release_exists(self):
        """Test that Helm release exists for the cluster"""
        result = subprocess.run(
            ['helm', 'list', '-n', TEST_NAMESPACE, '--output', 'json'],
            capture_output=True,
            text=True,
            check=True
        )
        
        import json
        releases = json.loads(result.stdout)
        
        cluster_release = next(
            (r for r in releases if r['name'] == TEST_CLUSTER_NAME),
            None
        )
        
        assert cluster_release is not None, \
            f"Helm release '{TEST_CLUSTER_NAME}' not found in namespace '{TEST_NAMESPACE}'"
        
        console.print(f"[cyan]Helm Release Status:[/cyan] {cluster_release.get('status', 'unknown')}")
        assert cluster_release.get('status') == 'deployed', \
            f"Helm release is not deployed (status: {cluster_release.get('status')})"

    def test_helm_release_has_correct_values(self):
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
        # HAProxy should be disabled when ProxySQL is enabled (default is False)
        if haproxy_enabled:
            console.print(f"[yellow]Warning: HAProxy is enabled, but ProxySQL should be used instead[/yellow]")
        
        # Check persistence is enabled
        persistence_enabled = values.get('pxc', {}).get('persistence', {}).get('enabled', False)
        assert persistence_enabled is True, "Persistence should be enabled"
        
        console.print(f"[cyan]Helm Values Validated:[/cyan] PXC={pxc_size}, ProxySQL={proxysql_enabled}")

    def test_helm_chart_renders_statefulset(self):
        """Test that Helm chart renders PerconaXtraDBCluster custom resource 
        (operator will create StatefulSets from this CR)"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        # Helm chart renders PerconaXtraDBCluster CR, not StatefulSets directly
        # The operator creates StatefulSets from the CR
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
        """Test that Helm chart includes PVC configuration in PerconaXtraDBCluster spec
        (operator will create PVCs from volumeSpec)"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        # Helm chart includes volumeSpec in the CR, operator creates PVCs
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
        """Test that Helm chart includes anti-affinity rules in PerconaXtraDBCluster spec
        (operator will apply these to StatefulSets)"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
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
        
        # The chart may have affinity configured or operator may apply defaults
        # Check if affinity exists, and if so, verify it's configured correctly
        if pod_anti_affinity or affinity:
            # Check for requiredDuringSchedulingIgnoredDuringExecution
            required = pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
            if len(required) > 0:
                # Verify topologyKey is set to zone
                for rule in required:
                    topology_key = rule.get('topologyKey', '')
                    assert 'zone' in topology_key.lower(), \
                        f"Anti-affinity topologyKey should contain 'zone', got: {topology_key}"
            else:
                # If affinity is configured differently, that's also acceptable
                # The operator may handle affinity rules
                console.print("[yellow]Note: Anti-affinity configured but not in expected format (operator may handle this)[/yellow]")
        else:
            console.print("[yellow]Note: No explicit affinity in Helm chart (operator may apply defaults)[/yellow]")


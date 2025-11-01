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
        
        # Check HAProxy is disabled
        haproxy_enabled = values.get('haproxy', {}).get('enabled', True)
        assert haproxy_enabled is False, "HAProxy should be disabled when ProxySQL is enabled"
        
        # Check persistence is enabled
        persistence_enabled = values.get('pxc', {}).get('persistence', {}).get('enabled', False)
        assert persistence_enabled is True, "Persistence should be enabled"
        
        console.print(f"[cyan]Helm Values Validated:[/cyan] PXC={pxc_size}, ProxySQL={proxysql_enabled}")

    def test_helm_chart_renders_statefulset(self):
        """Test that Helm chart renders StatefulSet resources"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        assert 'StatefulSet' in result.stdout, "Helm chart should render StatefulSet resources"
        
        # Parse and verify StatefulSet
        manifests = []
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'StatefulSet':
                manifests.append(doc)
        
        assert len(manifests) >= 2, \
            f"Expected at least 2 StatefulSets (PXC and ProxySQL), found {len(manifests)}"

    def test_helm_chart_renders_pvc(self):
        """Test that Helm chart renders PVC resources"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        assert 'PersistentVolumeClaim' in result.stdout, \
            "Helm chart should render PersistentVolumeClaim resources"

    def test_helm_chart_anti_affinity_rules(self):
        """Test that Helm chart includes anti-affinity rules"""
        result = subprocess.run(
            ['helm', 'template', 'test-chart', 'percona/pxc-db', '--namespace', TEST_NAMESPACE],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        # Check for podAntiAffinity in PXC StatefulSet
        manifests = list(yaml.safe_load_all(result.stdout))
        
        pxc_sts = next(
            (m for m in manifests if m.get('kind') == 'StatefulSet' and 'pxc' in m.get('metadata', {}).get('name', '').lower()),
            None
        )
        
        assert pxc_sts is not None, "PXC StatefulSet not found in Helm chart"
        
        affinity = pxc_sts.get('spec', {}).get('template', {}).get('spec', {}).get('affinity', {})
        pod_anti_affinity = affinity.get('podAntiAffinity', {})
        
        assert pod_anti_affinity is not None and len(pod_anti_affinity) > 0, \
            "PXC StatefulSet should have podAntiAffinity rules"
        
        # Check for requiredDuringSchedulingIgnoredDuringExecution
        required = pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
        assert len(required) > 0, \
            "PXC should have requiredDuringSchedulingIgnoredDuringExecution anti-affinity rules"
        
        # Verify topologyKey is set to zone
        for rule in required:
            topology_key = rule.get('topologyKey', '')
            assert 'zone' in topology_key.lower(), \
                f"Anti-affinity topologyKey should contain 'zone', got: {topology_key}"


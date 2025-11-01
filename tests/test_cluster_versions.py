"""
Test Percona XtraDB Cluster versions and image tags
"""
import pytest
import subprocess
import json
from kubernetes import client
from rich.console import Console
from tests.conftest import kubectl_cmd, TEST_NAMESPACE, TEST_CLUSTER_NAME, TEST_EXPECTED_NODES

console = Console()


class TestClusterVersions:
    """Test cluster versions and component versions"""

    def test_kubernetes_version_compatibility(self):
        """Test that Kubernetes version is compatible with Percona Operator (>= 1.24)"""
        result = subprocess.run(
            ['kubectl', 'version', '--output=json'],
            capture_output=True,
            text=True,
            check=True
        )
        version_info = json.loads(result.stdout)
        
        # Extract server version
        server_version = version_info['serverVersion']['gitVersion']
        # Remove 'v' prefix and get major.minor
        version_parts = server_version.lstrip('v').split('.')
        major = int(version_parts[0])
        minor = int(version_parts[1])
        
        console.print(f"[cyan]Kubernetes Version:[/cyan] {major}.{minor}")
        
        assert major > 1 or (major == 1 and minor >= 24), \
            f"Kubernetes version {major}.{minor} is too old. Percona Operator requires >= 1.24"
    
    def test_operator_version(self, core_v1):
        """Test that Percona Operator is installed and check its version"""
        # Try multiple label selectors for operator pods (helm chart uses pxc-operator)
        pods = None
        for label in ['app.kubernetes.io/name=pxc-operator', 
                      'app.kubernetes.io/name=percona-xtradb-cluster-operator',
                      'app.kubernetes.io/component=operator']:
            try:
                result = core_v1.list_namespaced_pod(
                    namespace=TEST_NAMESPACE,
                    label_selector=label
                )
                if len(result.items) > 0:
                    pods = result
                    break
            except:
                continue
        
        # Fallback: get all pods and filter by name pattern
        if not pods or len(pods.items) == 0:
            all_pods = core_v1.list_namespaced_pod(namespace=TEST_NAMESPACE)
            operator_pods = [p for p in all_pods.items if 'operator' in p.metadata.name and 'pxc' in p.metadata.name]
            if operator_pods:
                # Create a mock result object with items attribute
                class MockResult:
                    def __init__(self, items):
                        self.items = items
                pods = MockResult(operator_pods)
        
        assert pods and len(pods.items) > 0, "Percona Operator pod not found"
        
        operator_pod = pods.items[0]
        image = operator_pod.spec.containers[0].image
        
        console.print(f"[cyan]Operator Image:[/cyan] {image}")
        
        # Verify operator pod is running
        assert operator_pod.status.phase == 'Running', \
            f"Operator pod is not Running (status: {operator_pod.status.phase})"
        
        # Check image tag exists
        assert ':' in image, f"Operator image missing tag: {image}"
    
    def test_pxc_image_version(self, core_v1):
        """Test PXC pod image versions are consistent"""
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        assert len(pods.items) > 0, "No PXC pods found"
        
        images = set()
        for pod in pods.items:
            for container in pod.spec.containers:
                if 'pxc' in container.name.lower() or 'mysql' in container.name.lower():
                    images.add(container.image)
                    console.print(f"[cyan]PXC Pod {pod.metadata.name} Image:[/cyan] {container.image}")
        
        # All PXC pods should use the same image version
        assert len(images) == 1, \
            f"PXC pods are using different image versions: {images}"
        
        # Verify image has a version tag
        image = list(images)[0]
        assert ':' in image and image.split(':')[1] not in ('latest', ''), \
            f"PXC image should have a specific version tag, not 'latest' or empty: {image}"
    
    def test_proxysql_image_version(self, core_v1):
        """Test ProxySQL pod image versions are consistent"""
        pods = core_v1.list_namespaced_pod(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        assert len(pods.items) > 0, "No ProxySQL pods found"
        
        images = set()
        for pod in pods.items:
            for container in pod.spec.containers:
                images.add(container.image)
                console.print(f"[cyan]ProxySQL Pod {pod.metadata.name} Image:[/cyan] {container.image}")
        
        # All ProxySQL pods should use the same image version
        assert len(images) == 1, \
            f"ProxySQL pods are using different image versions: {images}"
        
        # Verify image has a version tag (expected: percona/proxysql2:2.7.3 or similar)
        image = list(images)[0]
        assert 'proxysql' in image.lower(), f"Expected ProxySQL image, got: {image}"
        assert ':' in image and image.split(':')[1] not in ('latest', ''), \
            f"ProxySQL image should have a specific version tag: {image}"
    
    def test_cluster_custom_resource_exists(self, custom_objects_v1):
        """Test that PXC custom resource exists"""
        try:
            cr = custom_objects_v1.get_namespaced_custom_object(
                group='pxc.percona.com',
                version='v1',
                namespace=TEST_NAMESPACE,
                plural='perconaxtradbclusters',
                name=f'{TEST_CLUSTER_NAME}-pxc-db'
            )
            
            console.print(f"[cyan]PXC CR Found:[/cyan] {cr['metadata']['name']}")
            console.print(f"[cyan]Status:[/cyan] {cr.get('status', {}).get('state', 'unknown')}")
            
            assert cr is not None, "PXC custom resource not found"
        except client.exceptions.ApiException as e:
            pytest.fail(f"PXC custom resource not found: {e}")
    
    def test_cluster_status_ready(self, custom_objects_v1):
        """Test that cluster status is 'ready'"""
        cr = custom_objects_v1.get_namespaced_custom_object(
            group='pxc.percona.com',
            version='v1',
            namespace=TEST_NAMESPACE,
            plural='perconaxtradbclusters',
            name=f'{TEST_CLUSTER_NAME}-pxc-db'
        )
        
        status = cr.get('status', {})
        state = status.get('state', 'unknown')
        
        console.print(f"[cyan]Cluster State:[/cyan] {state}")
        
        # Check PXC ready count
        pxc_status = status.get('pxc', {})
        if isinstance(pxc_status, dict):
            pxc_ready = pxc_status.get('ready', 0)
        else:
            pxc_ready = pxc_status
        
        # Check ProxySQL ready count
        proxysql_status = status.get('proxysql', {})
        if isinstance(proxysql_status, dict):
            proxysql_ready = proxysql_status.get('ready', 0)
        else:
            proxysql_ready = proxysql_status
        
        console.print(f"[cyan]PXC Ready:[/cyan] {pxc_ready}/{TEST_EXPECTED_NODES}")
        console.print(f"[cyan]ProxySQL Ready:[/cyan] {proxysql_ready}")
        
        assert state == 'ready', f"Cluster state is '{state}', expected 'ready'"
        assert pxc_ready >= TEST_EXPECTED_NODES, \
            f"Not all PXC nodes are ready: {pxc_ready}/{TEST_EXPECTED_NODES}"
        assert proxysql_ready > 0, "No ProxySQL pods are ready"


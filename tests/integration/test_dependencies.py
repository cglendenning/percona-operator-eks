"""
Integration tests: Verify dependencies (K8s version, Helm repo, StorageClass, etc.)
"""
import pytest
import subprocess
import json
from kubernetes import client
from rich.console import Console
from tests.conftest import TEST_NAMESPACE

console = Console()


@pytest.mark.integration
class TestKubernetesDependencies:
    """Test Kubernetes cluster dependencies"""
    
    def test_kubernetes_version_compatibility(self):
        """Test that Kubernetes version is compatible with Percona Operator (>= 1.24)"""
        result = subprocess.run(
            ['kubectl', 'version', '--output=json'],
            capture_output=True,
            text=True,
            check=True
        )
        version_info = json.loads(result.stdout)
        
        server_version = version_info['serverVersion']['gitVersion']
        version_parts = server_version.lstrip('v').split('.')
        major = int(version_parts[0])
        minor = int(version_parts[1])
        
        console.print(f"[cyan]Kubernetes Version:[/cyan] {major}.{minor}")
        
        assert major > 1 or (major == 1 and minor >= 24), \
            f"Kubernetes version {major}.{minor} is too old. Percona Operator requires >= 1.24"
    
    def test_storage_class_exists(self, storage_v1):
        """Test that gp3 storage class exists"""
        try:
            sc = storage_v1.read_storage_class(name='gp3')
            console.print(f"[cyan]StorageClass gp3:[/cyan] {sc.provisioner}")
            
            assert sc.provisioner == 'ebs.csi.aws.com', \
                f"StorageClass gp3 has wrong provisioner: {sc.provisioner}"
            
            assert sc.allow_volume_expansion is True, \
                "StorageClass gp3 should allow volume expansion"
        except client.exceptions.ApiException as e:
            if e.status == 404:
                pytest.fail("StorageClass 'gp3' not found")
            raise
    
    def test_storage_class_parameters(self, storage_v1):
        """Test that gp3 storage class has correct parameters"""
        sc = storage_v1.read_storage_class(name='gp3')
        params = sc.parameters or {}
        
        assert params.get('encrypted') == 'true' or params.get('encrypted') == 'True', \
            "StorageClass gp3 should have encryption enabled"
        
        assert sc.volume_binding_mode == 'WaitForFirstConsumer', \
            f"StorageClass gp3 should use WaitForFirstConsumer binding mode, got: {sc.volume_binding_mode"
    
    def test_nodes_have_zone_labels(self, core_v1):
        """Test that nodes have zone labels for anti-affinity to work"""
        nodes = core_v1.list_node()
        
        zones_found = set()
        for node in nodes.items:
            zone = (
                node.metadata.labels.get('topology.kubernetes.io/zone') or
                node.metadata.labels.get('failure-domain.beta.kubernetes.io/zone')
            )
            if zone:
                zones_found.add(zone)
        
        console.print(f"[cyan]Nodes with zone labels:[/cyan] {len(zones_found)} zones")
        
        assert len(zones_found) > 0, \
            "No nodes have zone labels - anti-affinity rules cannot work"
        
        assert len(zones_found) >= 2, \
            f"Only {len(zones_found)} zone(s) found - need at least 2 for multi-AZ deployment"


@pytest.mark.integration
class TestHelmDependencies:
    """Test Helm dependencies"""
    
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


@pytest.mark.integration
class TestBackupDependencies:
    """Test backup service dependencies"""
    
    def test_backup_secret_exists(self, core_v1):
        """Test that backup credentials secret exists"""
        secrets = core_v1.list_namespaced_secret(
            namespace=TEST_NAMESPACE,
            label_selector=None
        )
        
        backup_secrets = [
            s for s in secrets.items
            if 'backup' in s.metadata.name.lower() and ('minio' in s.metadata.name.lower() or 's3' in s.metadata.name.lower())
        ]
        
        assert len(backup_secrets) > 0, \
            "Backup credentials secret not found (expected: percona-backup-minio-credentials or percona-backup-s3-credentials)"
        
        secret = backup_secrets[0]
        console.print(f"[cyan]Backup Secret Found:[/cyan] {secret.metadata.name}")


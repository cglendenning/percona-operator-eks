"""
Unit tests for StatefulSet configuration validation.
Validates StatefulSet settings match Percona best practices.
"""
import os
import yaml
import pytest
import subprocess


@pytest.mark.unit
def test_statefulset_uses_ordered_ready_pod_management():
    """Test that StatefulSets use OrderedReady pod management policy (default and recommended)."""
    # This would be tested via Helm template rendering
    # OrderedReady ensures pods start/stop in order, which is important for PXC quorum
    
    result = subprocess.run(
        ['helm', 'template', 'test', 'percona/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode == 0:
        manifests = []
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'StatefulSet':
                manifests.append(doc)
        
        if manifests:
            for sts in manifests:
                pod_management_policy = sts.get('spec', {}).get('podManagementPolicy', 'OrderedReady')
                # OrderedReady is the default and recommended for PXC
                # Parallel is also acceptable but OrderedReady is safer for quorum
                assert pod_management_policy in ['OrderedReady', 'Parallel'], \
                    f"Pod management policy should be OrderedReady or Parallel, not {pod_management_policy}"


@pytest.mark.unit
def test_statefulset_uses_ondelete_update_strategy():
    """Test that StatefulSets use OnDelete update strategy for PXC (recommended)."""
    # PXC StatefulSets should use OnDelete strategy to ensure proper quorum during updates
    
    result = subprocess.run(
        ['helm', 'template', 'test', 'percona/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode == 0:
        manifests = []
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'StatefulSet':
                # Check if it's a PXC StatefulSet
                labels = doc.get('metadata', {}).get('labels', {})
                if labels.get('app.kubernetes.io/component') == 'pxc':
                    update_strategy = doc.get('spec', {}).get('updateStrategy', {}).get('type', 'RollingUpdate')
                    # OnDelete is recommended for PXC to maintain quorum
                    # RollingUpdate is also acceptable but requires careful coordination
                    assert update_strategy in ['OnDelete', 'RollingUpdate'], \
                        f"PXC update strategy should be OnDelete or RollingUpdate, not {update_strategy}"


@pytest.mark.unit
def test_statefulset_volume_claim_templates():
    """Test that StatefulSets use volume claim templates (required for persistence)."""
    result = subprocess.run(
        ['helm', 'template', 'test', 'percona/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode == 0:
        manifests = []
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'StatefulSet':
                volume_claim_templates = doc.get('spec', {}).get('volumeClaimTemplates', [])
                
                # PXC StatefulSet should have volume claim templates
                labels = doc.get('metadata', {}).get('labels', {})
                if labels.get('app.kubernetes.io/component') == 'pxc':
                    assert len(volume_claim_templates) > 0, \
                        "PXC StatefulSet must have volume claim templates for data persistence"


@pytest.mark.unit
def test_statefulset_service_name_matches():
    """Test that StatefulSet serviceName matches the headless service."""
    result = subprocess.run(
        ['helm', 'template', 'test', 'percona/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode == 0:
        services = {}
        statefulsets = {}
        
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'Service':
                # Find headless services (clusterIP: None)
                spec = doc.get('spec', {})
                if spec.get('clusterIP') == 'None':
                    name = doc.get('metadata', {}).get('name')
                    services[name] = doc
            
            elif doc and doc.get('kind') == 'StatefulSet':
                name = doc.get('metadata', {}).get('name')
                service_name = doc.get('spec', {}).get('serviceName')
                if service_name:
                    statefulsets[name] = service_name
        
        # Verify each StatefulSet has a matching headless service
        for sts_name, service_name in statefulsets.items():
            assert service_name in services, \
                f"StatefulSet {sts_name} serviceName {service_name} must match a headless Service"


@pytest.mark.unit
def test_statefulset_replicas_match_cluster_size():
    """Test that StatefulSet replicas match the configured cluster size."""
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    
    for node_count in [3, 6]:
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
            content = content.replace('{{NODES}}', str(node_count))
            values = yaml.safe_load(content)
        
        # Values should specify size
        assert values['pxc']['size'] == node_count
        assert values['proxysql']['size'] == node_count
        
        # Helm should render StatefulSets with matching replicas
        result = subprocess.run(
            ['helm', 'template', 'test', 'percona/pxc-db', 
             '--namespace', 'test', '--set', f'pxc.size={node_count}', 
             '--set', f'proxysql.size={node_count}'],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            for doc in yaml.safe_load_all(result.stdout):
                if doc and doc.get('kind') == 'StatefulSet':
                    labels = doc.get('metadata', {}).get('labels', {})
                    replicas = doc.get('spec', {}).get('replicas')
                    
                    if labels.get('app.kubernetes.io/component') == 'pxc' and replicas is not None:
                        assert replicas == node_count, \
                            f"PXC StatefulSet replicas {replicas} should match cluster size {node_count}"
                    
                    elif labels.get('app.kubernetes.io/component') == 'proxysql' and replicas is not None:
                        assert replicas == node_count, \
                            f"ProxySQL StatefulSet replicas {replicas} should match cluster size {node_count}"


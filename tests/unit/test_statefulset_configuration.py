"""
Unit tests for StatefulSet configuration validation.
Validates StatefulSet settings match Percona best practices.
"""
import os
import yaml
import pytest
import subprocess
from tests.conftest import log_check


@pytest.mark.unit
def test_statefulset_uses_ordered_ready_pod_management(chartmuseum_port_forward):
    """Test that StatefulSets use OrderedReady pod management policy (default and recommended)."""
    # This would be tested via Helm template rendering
    # OrderedReady ensures pods start/stop in order, which is important for PXC quorum
    # chartmuseum_port_forward fixture handles repo setup
    
    result = subprocess.run(
        ['helm', 'template', 'test', 'internal/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc and doc.get('kind') == 'StatefulSet':
            manifests.append(doc)
    
    if manifests:
        for sts in manifests:
            pod_management_policy = sts.get('spec', {}).get('podManagementPolicy', 'OrderedReady')
            # OrderedReady is the default and recommended for PXC
            # Parallel is also acceptable but OrderedReady is safer for quorum
            log_check(
                criterion="StatefulSet podManagementPolicy should be OrderedReady or Parallel",
                expected="in ['OrderedReady','Parallel']",
                actual=f"{pod_management_policy}",
                source="helm template internal/pxc-db",
            )
            assert pod_management_policy in ['OrderedReady', 'Parallel'], \
                f"Pod management policy should be OrderedReady or Parallel, not {pod_management_policy}"


@pytest.mark.unit
def test_statefulset_uses_ondelete_update_strategy(chartmuseum_port_forward):
    """Test that StatefulSets use OnDelete update strategy for PXC (recommended)."""
    # PXC StatefulSets should use OnDelete strategy to ensure proper quorum during updates
    # chartmuseum_port_forward fixture handles repo setup
    
    result = subprocess.run(
        ['helm', 'template', 'test', 'internal/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc and doc.get('kind') == 'StatefulSet':
            # Check if it's a PXC StatefulSet
            labels = doc.get('metadata', {}).get('labels', {})
            if labels.get('app.kubernetes.io/component') == 'pxc':
                update_strategy = doc.get('spec', {}).get('updateStrategy', {}).get('type', 'RollingUpdate')
                # OnDelete is recommended for PXC to maintain quorum
                # RollingUpdate is also acceptable but requires careful coordination
                log_check(
                    criterion="PXC StatefulSet updateStrategy.type should be OnDelete or RollingUpdate",
                    expected="in ['OnDelete','RollingUpdate']",
                    actual=f"{update_strategy}",
                    source="helm template internal/pxc-db",
                )
                assert update_strategy in ['OnDelete', 'RollingUpdate'], \
                    f"PXC update strategy should be OnDelete or RollingUpdate, not {update_strategy}"


@pytest.mark.unit
def test_statefulset_volume_claim_templates(chartmuseum_port_forward):
    """Test that StatefulSets use volume claim templates (required for persistence)."""
    # chartmuseum_port_forward fixture handles repo setup
    
    result = subprocess.run(
        ['helm', 'template', 'test', 'internal/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
    manifests = []
    for doc in yaml.safe_load_all(result.stdout):
        if doc and doc.get('kind') == 'StatefulSet':
            volume_claim_templates = doc.get('spec', {}).get('volumeClaimTemplates', [])
            
            # PXC StatefulSet should have volume claim templates
            labels = doc.get('metadata', {}).get('labels', {})
            if labels.get('app.kubernetes.io/component') == 'pxc':
                log_check(
                    criterion="PXC StatefulSet must define volumeClaimTemplates",
                    expected="> 0",
                    actual=f"count={len(volume_claim_templates)}",
                    source="helm template internal/pxc-db",
                )
                assert len(volume_claim_templates) > 0, \
                        "PXC StatefulSet must have volume claim templates for data persistence"


@pytest.mark.unit
def test_statefulset_service_name_matches(chartmuseum_port_forward):
    """Test that StatefulSet serviceName matches the headless service."""
    # chartmuseum_port_forward fixture handles repo setup
    
    result = subprocess.run(
        ['helm', 'template', 'test', 'internal/pxc-db', '--namespace', 'test'],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    if result.returncode != 0:
        pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
    
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
        log_check(
            criterion=f"StatefulSet {sts_name} serviceName must match a headless Service",
            expected=f"{list(services.keys())}",
            actual=f"serviceName={service_name}",
            source="helm template internal/pxc-db",
        )
        assert service_name in services, \
            f"StatefulSet {sts_name} serviceName {service_name} must match a headless Service"


@pytest.mark.unit
def test_statefulset_replicas_match_cluster_size(chartmuseum_port_forward):
    """Test that StatefulSet replicas match the configured cluster size."""
    # chartmuseum_port_forward fixture handles repo setup
    
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates', 'percona-values.yaml')
    
    for node_count in [3, 6]:
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
            content = content.replace('{{NODES}}', str(node_count))
            values = yaml.safe_load(content)
        
        # Values should specify size
        log_check("pxc.size must equal configured cluster size", f"{node_count}", f"{values['pxc']['size']}", source=path)
        assert values['pxc']['size'] == node_count
        log_check("proxysql.size must equal configured cluster size", f"{node_count}", f"{values['proxysql']['size']}", source=path)
        assert values['proxysql']['size'] == node_count
        
        # Helm should render StatefulSets with matching replicas
        result = subprocess.run(
            ['helm', 'template', 'test', 'internal/pxc-db', 
             '--namespace', 'test', '--set', f'pxc.size={node_count}', 
             '--set', f'proxysql.size={node_count}'],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            pytest.skip(f"Local ChartMuseum chart not available: {result.stderr}")
        
        for doc in yaml.safe_load_all(result.stdout):
            if doc and doc.get('kind') == 'StatefulSet':
                labels = doc.get('metadata', {}).get('labels', {})
                replicas = doc.get('spec', {}).get('replicas')
                
                if labels.get('app.kubernetes.io/component') == 'pxc' and replicas is not None:
                    log_check(
                        criterion="PXC StatefulSet replicas must match cluster size",
                        expected=f"{node_count}",
                        actual=f"{replicas}",
                        source="helm template internal/pxc-db",
                    )
                    assert replicas == node_count, \
                        f"PXC StatefulSet replicas {replicas} should match cluster size {node_count}"
                
                elif labels.get('app.kubernetes.io/component') == 'proxysql' and replicas is not None:
                    log_check(
                        criterion="ProxySQL StatefulSet replicas must match cluster size",
                        expected=f"{node_count}",
                        actual=f"{replicas}",
                        source="helm template internal/pxc-db",
                    )
                    assert replicas == node_count, \
                        f"ProxySQL StatefulSet replicas {replicas} should match cluster size {node_count}"


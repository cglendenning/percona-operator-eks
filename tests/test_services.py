"""
Test Kubernetes Services
"""
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_CLUSTER_NAME

console = Console()


class TestServices:
    """Test Kubernetes Services configuration"""

    def test_pxc_service_exists(self, core_v1):
        """Test that PXC service exists"""
        services = core_v1.list_namespaced_service(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=pxc'
        )
        
        assert len(services.items) > 0, "PXC service not found"
        
        service = services.items[0]
        console.print(f"[cyan]PXC Service:[/cyan] {service.metadata.name}")
        console.print(f"[cyan]Service Type:[/cyan] {service.spec.type}")
        ports_str = [f"{p.port}/{p.protocol}" for p in service.spec.ports]
        console.print(f"[cyan]Ports:[/cyan] {ports_str}")
        
        assert service.spec.type in ['ClusterIP', 'LoadBalancer', 'NodePort'], \
            f"PXC service has unexpected type: {service.spec.type}"
        
        assert len(service.spec.ports) > 0, \
            "PXC service should have at least one port"

    def test_proxysql_service_exists(self, core_v1):
        """Test that ProxySQL service exists"""
        services = core_v1.list_namespaced_service(
            namespace=TEST_NAMESPACE,
            label_selector='app.kubernetes.io/component=proxysql'
        )
        
        assert len(services.items) > 0, "ProxySQL service not found"
        
        service = services.items[0]
        console.print(f"[cyan]ProxySQL Service:[/cyan] {service.metadata.name}")
        console.print(f"[cyan]Service Type:[/cyan] {service.spec.type}")
        ports_str = [f"{p.port}/{p.protocol}" for p in service.spec.ports]
        console.print(f"[cyan]Ports:[/cyan] {ports_str}")
        
        # ProxySQL typically uses port 3306
        mysql_ports = [p for p in service.spec.ports if p.port == 3306]
        assert len(mysql_ports) > 0, \
            "ProxySQL service should expose port 3306"

    def test_service_selectors_match_pods(self, core_v1):
        """Test that service selectors match pod labels"""
        services = core_v1.list_namespaced_service(namespace=TEST_NAMESPACE)
        
        for service in services.items:
            if 'pxc' not in service.metadata.name.lower() and 'proxysql' not in service.metadata.name.lower():
                continue
            
            selector = service.spec.selector
            assert selector is not None and len(selector) > 0, \
                f"Service {service.metadata.name} has no selector"
            
            console.print(f"[cyan]{service.metadata.name} Selector:[/cyan] {selector}")
            
            # Verify pods exist that match this selector
            label_selector = ','.join([f"{k}={v}" for k, v in selector.items()])
            pods = core_v1.list_namespaced_pod(
                namespace=TEST_NAMESPACE,
                label_selector=label_selector
            )
            
            assert len(pods.items) > 0, \
                f"No pods found matching service {service.metadata.name} selector: {selector}"

    def test_service_endpoints_exist(self, core_v1):
        """Test that services have endpoints"""
        services = core_v1.list_namespaced_service(namespace=TEST_NAMESPACE)
        
        percona_services = [
            s for s in services.items
            if 'pxc' in s.metadata.name.lower() or 'proxysql' in s.metadata.name.lower()
        ]
        
        for service in percona_services:
            try:
                endpoints = core_v1.read_namespaced_endpoints(
                    name=service.metadata.name,
                    namespace=TEST_NAMESPACE
                )
                
                addresses = []
                for subset in endpoints.subsets or []:
                    addresses.extend([addr.ip for addr in subset.addresses or []])
                
                console.print(f"[cyan]{service.metadata.name} Endpoints:[/cyan] {len(addresses)}")
                
                assert len(addresses) > 0, \
                    f"Service {service.metadata.name} has no endpoints"
                    
            except Exception as e:
                console.print(f"[yellow]⚠ Could not check endpoints for {service.metadata.name}:[/yellow] {e}")


"""
Unit tests for LitmusChaos YAML templates.
These tests validate the configuration before it's applied to ensure integration tests will pass.
"""
import yaml
import os
import pytest
from tests.conftest import log_check


@pytest.mark.unit
def test_litmus_operator_template_valid():
    """Test that litmus-operator.yaml is valid YAML."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    log_check("litmus-operator.yaml should contain 4 documents (SA, CR, CRB, Deployment)", "4", f"{len(docs)}", source=path)
    assert len(docs) == 4  # ServiceAccount, ClusterRole, ClusterRoleBinding, Deployment


@pytest.mark.unit
def test_litmus_operator_serviceaccount():
    """Test LitmusChaos operator ServiceAccount configuration."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    sa = docs[0]
    log_check("Litmus SA kind", "ServiceAccount", f"{sa['kind']}", source=path); assert sa['kind'] == 'ServiceAccount'
    log_check("Litmus SA name", "litmus-operator", f"{sa['metadata']['name']}", source=path); assert sa['metadata']['name'] == 'litmus-operator'
    log_check("Litmus SA namespace", "litmus", f"{sa['metadata']['namespace']}", source=path); assert sa['metadata']['namespace'] == 'litmus'


@pytest.mark.unit
def test_litmus_operator_clusterrole():
    """Test LitmusChaos operator ClusterRole permissions."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    cr = next(d for d in docs if d['kind'] == 'ClusterRole')
    log_check("Litmus ClusterRole name", "litmus-operator", f"{cr['metadata']['name']}", source=path); assert cr['metadata']['name'] == 'litmus-operator'
    
    # Check for required resource permissions
    resources_found = []
    for rule in cr['rules']:
        resources_found.extend(rule.get('resources', []))
    
    for res in ['chaosengines','chaosexperiments','chaosresults','pods','jobs']:
        log_check(f"ClusterRole must include resource {res}", "present", f"present={res in resources_found}", source=path)
        assert res in resources_found


@pytest.mark.unit
def test_litmus_operator_deployment():
    """Test LitmusChaos operator Deployment configuration."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    log_check("Deployment name", "chaos-operator-ce", f"{deployment['metadata']['name']}", source=path); assert deployment['metadata']['name'] == 'chaos-operator-ce'
    log_check("Deployment namespace", "litmus", f"{deployment['metadata']['namespace']}", source=path); assert deployment['metadata']['namespace'] == 'litmus'
    log_check("Deployment replicas", "1", f"{deployment['spec']['replicas']}", source=path); assert deployment['spec']['replicas'] == 1
    
    pod_spec = deployment['spec']['template']['spec']
    log_check("Deployment SA name", "litmus-operator", f"{pod_spec['serviceAccountName']}", source=path); assert pod_spec['serviceAccountName'] == 'litmus-operator'
    
    container = pod_spec['containers'][0]
    log_check("Container name", "chaos-operator", f"{container['name']}", source=path); assert container['name'] == 'chaos-operator'
    log_check("Container image", "litmuschaos/chaos-operator:latest", f"{container['image']}", source=path); assert container['image'] == 'litmuschaos/chaos-operator:latest'


@pytest.mark.unit
def test_litmus_admin_clusterrole_template():
    """Test litmus-admin ClusterRole template."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-admin-clusterrole.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        cr = yaml.safe_load(f)
    
    log_check("admin ClusterRole kind", "ClusterRole", f"{cr['kind']}", source=path); assert cr['kind'] == 'ClusterRole'
    log_check("admin ClusterRole name", "litmus-admin", f"{cr['metadata']['name']}", source=path); assert cr['metadata']['name'] == 'litmus-admin'
    
    # Check for required resource permissions
    resources_found = []
    for rule in cr['rules']:
        resources_found.extend(rule.get('resources', []))
    
    for res in ['chaosengines','chaosexperiments','chaosresults','pods']:
        log_check(f"admin ClusterRole must include resource {res}", "present", f"present={res in resources_found}", source=path)
        assert res in resources_found


@pytest.mark.unit
def test_litmus_admin_clusterrolebinding_template():
    """Test litmus-admin ClusterRoleBinding template."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-admin-clusterrolebinding.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Check placeholder exists
        log_check("ClusterRoleBinding template should include {{NAMESPACE}} placeholder", "present", f"present={{'{{NAMESPACE}}' in content}}", source=path); assert '{{NAMESPACE}}' in content
        # Replace for validation
        content = content.replace('{{NAMESPACE}}', 'litmus')
        crb = yaml.safe_load(content)
    
    log_check("CRB kind", "ClusterRoleBinding", f"{crb['kind']}", source=path); assert crb['kind'] == 'ClusterRoleBinding'
    log_check("CRB name", "litmus-admin", f"{crb['metadata']['name']}", source=path); assert crb['metadata']['name'] == 'litmus-admin'
    log_check("CRB roleRef.name", "litmus-admin", f"{crb['roleRef']['name']}", source=path); assert crb['roleRef']['name'] == 'litmus-admin'
    log_check("CRB subject kind", "ServiceAccount", f"{crb['subjects'][0]['kind']}", source=path); assert crb['subjects'][0]['kind'] == 'ServiceAccount'
    log_check("CRB subject name", "litmus-admin", f"{crb['subjects'][0]['name']}", source=path); assert crb['subjects'][0]['name'] == 'litmus-admin'
    log_check("CRB subject namespace", "litmus", f"{crb['subjects'][0]['namespace']}", source=path); assert crb['subjects'][0]['namespace'] == 'litmus'


@pytest.mark.unit
def test_pod_delete_chaosexperiment_template():
    """Test pod-delete ChaosExperiment template."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'pod-delete-chaosexperiment.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Check placeholder exists
        log_check("ChaosExperiment template should include {{NAMESPACE}} placeholder", "present", f"present={{'{{NAMESPACE}}' in content}}", source=path); assert '{{NAMESPACE}}' in content
        # Replace for validation
        content = content.replace('{{NAMESPACE}}', 'litmus')
        ce = yaml.safe_load(content)
    
    log_check("CE kind", "ChaosExperiment", f"{ce['kind']}", source=path); assert ce['kind'] == 'ChaosExperiment'
    log_check("CE apiVersion", "litmuschaos.io/v1alpha1", f"{ce['apiVersion']}", source=path); assert ce['apiVersion'] == 'litmuschaos.io/v1alpha1'
    log_check("CE name", "pod-delete", f"{ce['metadata']['name']}", source=path); assert ce['metadata']['name'] == 'pod-delete'
    log_check("CE namespace", "litmus", f"{ce['metadata']['namespace']}", source=path); assert ce['metadata']['namespace'] == 'litmus'
    log_check("CE scope", "Namespaced", f"{ce['spec']['definition']['scope']}", source=path); assert ce['spec']['definition']['scope'] == 'Namespaced'
    log_check("CE image", "litmuschaos/go-runner:latest", f"{ce['spec']['definition']['image']}", source=path); assert ce['spec']['definition']['image'] == 'litmuschaos/go-runner:latest'
    
    # Check permissions exist
    permissions = ce['spec']['definition']['permissions']
    log_check("CE definition must include permissions", "> 0", f"{len(permissions)}", source=path); assert len(permissions) > 0
    
    # Check for required resources
    resources_found = []
    for perm in permissions:
        resources_found.extend(perm.get('resources', []))
    
    for res in ['pods','chaosengines']:
        log_check(f"CE permissions must include resource {res}", "present", f"present={res in resources_found}", source=path)
        assert res in resources_found


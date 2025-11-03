"""
Unit tests for LitmusChaos YAML templates.
These tests validate the configuration before it's applied to ensure integration tests will pass.
"""
import yaml
import os
import pytest


@pytest.mark.unit
def test_litmus_operator_template_valid():
    """Test that litmus-operator.yaml is valid YAML."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    assert len(docs) == 4  # ServiceAccount, ClusterRole, ClusterRoleBinding, Deployment


@pytest.mark.unit
def test_litmus_operator_serviceaccount():
    """Test LitmusChaos operator ServiceAccount configuration."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    sa = docs[0]
    assert sa['kind'] == 'ServiceAccount'
    assert sa['metadata']['name'] == 'litmus-operator'
    assert sa['metadata']['namespace'] == 'litmus'


@pytest.mark.unit
def test_litmus_operator_clusterrole():
    """Test LitmusChaos operator ClusterRole permissions."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    cr = next(d for d in docs if d['kind'] == 'ClusterRole')
    assert cr['metadata']['name'] == 'litmus-operator'
    
    # Check for required resource permissions
    resources_found = []
    for rule in cr['rules']:
        resources_found.extend(rule.get('resources', []))
    
    assert 'chaosengines' in resources_found
    assert 'chaosexperiments' in resources_found
    assert 'chaosresults' in resources_found
    assert 'pods' in resources_found
    assert 'jobs' in resources_found


@pytest.mark.unit
def test_litmus_operator_deployment():
    """Test LitmusChaos operator Deployment configuration."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-operator.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    assert deployment['metadata']['name'] == 'chaos-operator-ce'
    assert deployment['metadata']['namespace'] == 'litmus'
    assert deployment['spec']['replicas'] == 1
    
    pod_spec = deployment['spec']['template']['spec']
    assert pod_spec['serviceAccountName'] == 'litmus-operator'
    
    container = pod_spec['containers'][0]
    assert container['name'] == 'chaos-operator'
    assert container['image'] == 'litmuschaos/chaos-operator:latest'


@pytest.mark.unit
def test_litmus_admin_clusterrole_template():
    """Test litmus-admin ClusterRole template."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-admin-clusterrole.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        cr = yaml.safe_load(f)
    
    assert cr['kind'] == 'ClusterRole'
    assert cr['metadata']['name'] == 'litmus-admin'
    
    # Check for required resource permissions
    resources_found = []
    for rule in cr['rules']:
        resources_found.extend(rule.get('resources', []))
    
    assert 'chaosengines' in resources_found
    assert 'chaosexperiments' in resources_found
    assert 'chaosresults' in resources_found
    assert 'pods' in resources_found


@pytest.mark.unit
def test_litmus_admin_clusterrolebinding_template():
    """Test litmus-admin ClusterRoleBinding template."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'litmus-admin-clusterrolebinding.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Check placeholder exists
        assert '{{NAMESPACE}}' in content
        # Replace for validation
        content = content.replace('{{NAMESPACE}}', 'litmus')
        crb = yaml.safe_load(content)
    
    assert crb['kind'] == 'ClusterRoleBinding'
    assert crb['metadata']['name'] == 'litmus-admin'
    assert crb['roleRef']['name'] == 'litmus-admin'
    assert crb['subjects'][0]['kind'] == 'ServiceAccount'
    assert crb['subjects'][0]['name'] == 'litmus-admin'
    assert crb['subjects'][0]['namespace'] == 'litmus'


@pytest.mark.unit
def test_pod_delete_chaosexperiment_template():
    """Test pod-delete ChaosExperiment template."""
    path = os.path.join(os.getcwd(), 'templates', 'litmuschaos', 'pod-delete-chaosexperiment.yaml')
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        # Check placeholder exists
        assert '{{NAMESPACE}}' in content
        # Replace for validation
        content = content.replace('{{NAMESPACE}}', 'litmus')
        ce = yaml.safe_load(content)
    
    assert ce['kind'] == 'ChaosExperiment'
    assert ce['apiVersion'] == 'litmuschaos.io/v1alpha1'
    assert ce['metadata']['name'] == 'pod-delete'
    assert ce['metadata']['namespace'] == 'litmus'
    assert ce['spec']['definition']['scope'] == 'Namespaced'
    assert ce['spec']['definition']['image'] == 'litmuschaos/go-runner:latest'
    
    # Check permissions exist
    permissions = ce['spec']['definition']['permissions']
    assert len(permissions) > 0
    
    # Check for required resources
    resources_found = []
    for perm in permissions:
        resources_found.extend(perm.get('resources', []))
    
    assert 'pods' in resources_found
    assert 'chaosengines' in resources_found


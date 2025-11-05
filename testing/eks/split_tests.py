#!/usr/bin/env python3
"""
Script to split test files into individual test files (one test per file)
"""
import ast
import os
import re
from pathlib import Path

# Map of test files to their category and test methods
test_categories = {
    'test_helm_charts.py': {
        'unit': ['test_helm_repo_available', 'test_helm_chart_values_valid', 'test_helm_chart_renders_statefulset', 'test_helm_chart_renders_pvc', 'test_helm_chart_anti_affinity_rules'],
        'integration': ['test_helm_release_exists', 'test_helm_release_has_correct_values']
    },
    'test_affinity_taints.py': {
        'integration': ['test_pxc_anti_affinity_rules', 'test_proxysql_anti_affinity_rules', 'test_pods_distributed_across_zones', 'test_proxysql_pods_distributed_across_zones', 'test_nodes_have_zone_labels', 'test_pods_can_have_tolerations']
    },
    'test_backups.py': {
        'integration': ['test_backup_secret_exists', 'test_backup_storage_configured', 'test_backup_schedules_exist', 'test_backup_cronjobs_exist', 'test_minio_accessible_and_writable']
    },
    'test_cluster_versions.py': {
        'integration': ['test_kubernetes_version_compatibility', 'test_operator_version', 'test_pxc_image_version', 'test_proxysql_image_version', 'test_cluster_custom_resource_exists', 'test_cluster_status_ready']
    },
    'test_pvcs_storage.py': {
        'integration': ['test_pvcs_exist_for_pxc', 'test_pvcs_exist_for_proxysql', 'test_pxc_pvc_storage_size', 'test_pxc_pvc_storage_class', 'test_proxysql_pvc_storage_size', 'test_storage_class_exists', 'test_storage_class_parameters', 'test_pvc_access_modes']
    },
    'test_resources_pdb.py': {
        'integration': ['test_pxc_resource_requests', 'test_pxc_resource_values', 'test_proxysql_resource_requests', 'test_proxysql_resource_values', 'test_pxc_pdb_exists', 'test_proxysql_pdb_exists']
    },
    'test_services.py': {
        'integration': ['test_pxc_service_exists', 'test_proxysql_service_exists', 'test_service_selectors_match_pods', 'test_service_endpoints_exist']
    },
    'test_statefulsets.py': {
        'integration': ['test_pxc_statefulset_exists', 'test_proxysql_statefulset_exists', 'test_statefulset_service_name', 'test_statefulset_update_strategy', 'test_statefulset_pod_management_policy', 'test_statefulset_volume_claim_templates']
    }
}

def extract_test_method(source_file, class_name, test_method_name):
    """Extract a specific test method from source code"""
    with open(source_file, 'r') as f:
        content = f.read()
    
    # Parse the file
    tree = ast.parse(content)
    
    # Find the class
    test_class = None
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == class_name:
            test_class = node
            break
    
    if not test_class:
        return None, None
    
    # Find the test method
    test_method = None
    for node in test_class.body:
        if isinstance(node, ast.FunctionDef) and node.name == test_method_name:
            test_method = node
            break
    
    if not test_method:
        return None, None
    
    # Get the method source code
    import astor
    try:
        method_source = astor.to_source(test_method)
    except:
        # Fallback: extract from original content
        lines = content.split('\n')
        start_line = test_method.lineno - 1
        end_line = test_method.end_lineno if hasattr(test_method, 'end_lineno') else start_line + 20
        method_source = '\n'.join(lines[start_line:end_line])
    
    # Get imports and docstring
    imports = []
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            imports.append(astor.to_source(node))
    
    class_doc = ast.get_docstring(test_class) or ''
    
    return imports, method_source

def create_individual_test_file(test_dir, category, test_name, imports, method_source, class_doc, test_doc):
    """Create an individual test file"""
    # Convert test name to file name (e.g., test_pxc_anti_affinity_rules -> test_pxc_anti_affinity_rules.py)
    file_name = f"{test_name}.py"
    file_path = Path(test_dir) / category / file_name
    
    # Marker based on category
    marker_map = {
        'unit': '@pytest.mark.unit',
        'integration': '@pytest.mark.integration',
        'resiliency': '@pytest.mark.resiliency'
    }
    marker = marker_map.get(category, '')
    
    # Create file content
    content = f'''"""
{test_doc}
"""
import pytest
from rich.console import Console
from tests.conftest import TEST_NAMESPACE, TEST_EXPECTED_NODES, TEST_CLUSTER_NAME, TEST_BACKUP_TYPE, TEST_BACKUP_BUCKET

console = Console()


{marker}
def {test_name}{method_source.split(test_name)[1].split('(')[1] if '(' in method_source.split(test_name)[1] else '()'}:
    """{test_doc}"""
{method_source.split('"""')[-1].split('def')[0].split('"""')[1] if '"""' in method_source else ''}
'''
    
    # This approach is getting complex. Let me use a simpler regex-based approach.
    return None

print("Test categorization complete. Will create individual files manually for accuracy.")


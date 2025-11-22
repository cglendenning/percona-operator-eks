"""
Unit tests for resource configuration (CPU, memory, storage).
Validates resource requests and limits match Percona recommendations.
"""
import os
import yaml
import pytest
import re
from conftest import log_check, get_values_for_test


def parse_resource_value(value_str):
    """Parse Kubernetes resource value (e.g., '1Gi', '500m') to comparable format.
    Returns:
      - CPU: millicores
      - Memory: bytes
    Note: If a bare number is provided, callers should convert to the appropriate unit
    based on context (e.g., cores→millicores for CPU). For memory, bare numbers are rare
    and treated as bytes.
    """
    if isinstance(value_str, (int, float)):
        # Treat bare numbers as bytes for memory context or cores for CPU (handled by caller)
        return float(value_str)
    
    value_str = str(value_str).strip()
    
    # CPU parsing (millicores)
    if value_str.endswith('m'):
        return float(value_str[:-1])  # millicores
    elif re.match(r'^\d+\.?\d*$', value_str):
        return float(value_str) * 1000  # cores to millicores
    
    # Memory parsing (bytes)
    memory_multipliers = {
        'Ki': 1024,
        'Mi': 1024 * 1024,
        'Gi': 1024 * 1024 * 1024,
        'K': 1000,
        'M': 1000 * 1000,
        'G': 1000 * 1000 * 1000,
    }
    
    for suffix, multiplier in memory_multipliers.items():
        if value_str.endswith(suffix):
            num = float(re.match(r'^(\d+\.?\d*)', value_str).group(1))
            return num * multiplier
    
    return 0


@pytest.mark.unit
def test_pxc_resource_requests():
    """Test PXC resource requests meet minimum requirements."""
    values, path = get_values_for_test()
    
    pxc_resources = values['pxc']['resources']
    
    # Minimum CPU request: 500m (0.5 cores)
    cpu_request = parse_resource_value(pxc_resources['requests']['cpu'])
    log_check("PXC min CPU request", ">= 500m", f"{cpu_request}m", source=path); assert cpu_request >= 500, "PXC minimum CPU request is 500m"
    
    # Minimum memory request: 1Gi
    memory_request = parse_resource_value(pxc_resources['requests']['memory'])
    min_memory_bytes = 1 * 1024 * 1024 * 1024  # 1Gi
    log_check("PXC min memory request", ">= 1Gi", f"{int(memory_request)} bytes", source=path); assert memory_request >= min_memory_bytes, "PXC minimum memory request is 1Gi"


@pytest.mark.unit
def test_pxc_resource_limits():
    """Test PXC resource limits are set appropriately."""
    values, path = get_values_for_test()
    
    pxc_resources = values['pxc']['resources']
    
    # Limits should be >= requests
    raw_cpu_limit = pxc_resources['limits']['cpu']
    raw_cpu_request = pxc_resources['requests']['cpu']
    cpu_limit = parse_resource_value(raw_cpu_limit)
    cpu_request = parse_resource_value(raw_cpu_request)
    # If limits/requests are specified as bare cores (e.g., 1), normalize to millicores
    if isinstance(raw_cpu_limit, (int, float)):
        cpu_limit *= 1000
    if isinstance(raw_cpu_request, (int, float)):
        cpu_request *= 1000
    log_check("PXC CPU limit >= request", ">= request", f"limit={cpu_limit}m, request={cpu_request}m", source=path); assert cpu_limit >= cpu_request, "CPU limit must be >= request"
    
    memory_limit = parse_resource_value(pxc_resources['limits']['memory'])
    memory_request = parse_resource_value(pxc_resources['requests']['memory'])
    log_check("PXC memory limit >= request", ">= request", f"limit={int(memory_limit)}, request={int(memory_request)}", source=path); assert memory_limit >= memory_request, "Memory limit must be >= request"
    
    # Recommended limits (at least 1 CPU)
    log_check("PXC CPU limit >= 1 core", ">= 1000m", f"{cpu_limit}m", source=path); assert cpu_limit >= 1000, "PXC should have at least 1 CPU limit"
    min_memory_limit = 2 * 1024 * 1024 * 1024  # 2Gi
    log_check("PXC memory limit >= 2Gi", ">= 2Gi", f"{int(memory_limit)} bytes", source=path); assert memory_limit >= min_memory_limit, "PXC should have at least 2Gi memory limit"


@pytest.mark.unit
def test_pxc_storage_size():
    """Test PXC storage size meets minimum requirements."""
    values, path = get_values_for_test()
    
    pxc = values['pxc']
    
    # On-prem uses volumeSpec (raw Kubernetes format)
    storage_size = pxc['volumeSpec']['persistentVolumeClaim']['resources']['requests']['storage']
    size_bytes = parse_resource_value(storage_size)
    
    # Minimum 10Gi for PXC
    min_storage = 10 * 1024 * 1024 * 1024  # 10Gi
    log_check("PXC minimum storage size", ">= 10Gi", f"{int(size_bytes)} bytes", source=path)
    assert size_bytes >= min_storage, "PXC minimum storage is 10Gi"


@pytest.mark.unit
def test_resources_use_read_write_once():
    """Test that all persistent volumes use ReadWriteOnce access mode."""
    values, path = get_values_for_test()
    
    pxc = values['pxc']
    
    # On-prem uses volumeSpec (raw Kubernetes format)
    access_modes = pxc['volumeSpec']['persistentVolumeClaim'].get('accessModes', [])
    log_check("PXC accessModes should include ReadWriteOnce", "ReadWriteOnce in list", f"{access_modes}", source=path)
    assert 'ReadWriteOnce' in access_modes, "PXC must use ReadWriteOnce access mode to prevent data corruption"

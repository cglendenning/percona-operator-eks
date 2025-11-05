"""
Unit tests for StatefulSet configuration validation.
Validates StatefulSet settings match Percona best practices.
"""
import os
import yaml
import pytest
import subprocess
from conftest import log_check, get_values_for_test


@pytest.mark.unit
def test_statefulset_uses_ordered_ready_pod_management(chartmuseum_port_forward):
    """Test that StatefulSets use OrderedReady pod management policy (default and recommended)."""
    pytest.skip("On-prem uses Fleet for deployment, StatefulSet config validated via rendered manifest")


@pytest.mark.unit
def test_statefulset_uses_ondelete_update_strategy(chartmuseum_port_forward):
    """Test that StatefulSets use OnDelete update strategy for PXC (recommended)."""
    pytest.skip("On-prem uses Fleet for deployment, StatefulSet config validated via rendered manifest")


@pytest.mark.unit
def test_statefulset_volume_claim_templates(chartmuseum_port_forward):
    """Test that StatefulSets use volume claim templates (required for persistence)."""
    pytest.skip("On-prem uses Fleet for deployment, StatefulSet config validated via rendered manifest")


@pytest.mark.unit
def test_statefulset_service_name_matches(chartmuseum_port_forward):
    """Test that StatefulSet serviceName matches the headless service."""
    pytest.skip("On-prem uses Fleet for deployment, StatefulSet config validated via rendered manifest")


@pytest.mark.unit
def test_statefulset_replicas_match_cluster_size(chartmuseum_port_forward):
    """Test that StatefulSet replicas match the configured cluster size."""
    pytest.skip("On-prem uses Fleet for deployment, StatefulSet config validated via rendered manifest")

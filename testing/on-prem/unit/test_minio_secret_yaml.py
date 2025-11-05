"""
Unit tests for MinIO credentials secret YAML.
"""
import yaml
import os
import pytest
from conftest import log_check


@pytest.mark.unit
def test_minio_credentials_secret_template_valid():
    """Test that MinIO credentials secret template is valid."""
    pytest.skip("On-prem uses Fleet-based secret configuration, not static template files")

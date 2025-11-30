"""
Unit test for XtraBackup version validation.
Validates that XtraBackup backup image version is 8.4.0-4.
"""
import os
import yaml
import pytest
from conftest import log_check, FLEET_RENDERED_MANIFEST


@pytest.mark.unit
def test_xtrabackup_version_pinned():
    """
    Test that XtraBackup backup image version is 8.4.0-4.
    
    How this test gathers information from the rendered manifest:
    
    1. The test loads the Fleet-rendered manifest, which contains all Kubernetes
       resources that will be deployed, including the PerconaXtraDBCluster custom resource.
    
    2. It searches through all YAML documents in the manifest to find the 
       PerconaXtraDBCluster resource (kind: PerconaXtraDBCluster).
    
    3. Within the PerconaXtraDBCluster spec, the backup configuration is defined under:
       spec.backup.image
       
       This image field specifies the XtraBackup container image used for backup operations.
    
    4. The image format is typically: percona/percona-xtradb-cluster-operator:VERSION-pxc8.4-backup
       or: percona/percona-xtradb-cluster-backup:VERSION
    
    5. The test extracts the version tag from the image string and validates it matches
       the expected version (8.4.0-4).
    
    Note: XtraBackup is the backup tool used by Percona XtraDB Cluster. It runs as a 
    sidecar container in backup pods and is also used for initial cluster seeding via SST
    (State Snapshot Transfer).
    """
    expected_version = "8.4.0-4"
    
    # Load the full Fleet-rendered manifest (contains all Kubernetes resources)
    if not FLEET_RENDERED_MANIFEST or not os.path.exists(FLEET_RENDERED_MANIFEST):
        pytest.skip("Fleet rendered manifest not available")
    
    with open(FLEET_RENDERED_MANIFEST, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    # Find the PerconaXtraDBCluster custom resource
    pxc_cluster = None
    for doc in docs:
        if doc and doc.get('kind') == 'PerconaXtraDBCluster':
            pxc_cluster = doc
            break
    
    if not pxc_cluster:
        pytest.skip("PerconaXtraDBCluster resource not found in rendered manifest")
    
    # Extract backup image from spec
    backup_config = pxc_cluster.get('spec', {}).get('backup', {})
    
    log_check(
        criterion="PerconaXtraDBCluster spec must have backup configuration",
        expected="backup config present",
        actual=f"present={bool(backup_config)}",
        source=FLEET_RENDERED_MANIFEST
    )
    assert backup_config, "PerconaXtraDBCluster must have backup configuration"
    
    backup_image = backup_config.get('image')
    
    log_check(
        criterion="Backup configuration must specify image",
        expected="image present",
        actual=f"image={backup_image}",
        source=FLEET_RENDERED_MANIFEST
    )
    assert backup_image, "Backup configuration must have image specified"
    
    # Extract version from image (format: repository/image:version)
    if ':' not in backup_image:
        pytest.fail(f"Backup image must include version tag, got: {backup_image}")
    
    actual_version = backup_image.split(':')[-1]
    
    # The backup image tag might contain additional suffixes like -pxc8.4-backup
    # We need to extract just the version part (e.g., "8.4.0-4" from "8.4.0-4-pxc8.4-backup")
    # Common formats:
    #   - 8.4.0-4-pxc8.4-backup
    #   - 8.4.0-4
    # We'll match the pattern X.Y.Z-N at the beginning
    import re
    version_match = re.match(r'^(\d+\.\d+\.\d+-\d+)', actual_version)
    if version_match:
        actual_version = version_match.group(1)
    
    log_check(
        criterion="XtraBackup version must be 8.4.0-4",
        expected=expected_version,
        actual=actual_version,
        source=FLEET_RENDERED_MANIFEST
    )
    assert actual_version == expected_version, \
        f"XtraBackup version must be {expected_version}, got {actual_version} (full image: {backup_image})"


@pytest.mark.unit
def test_xtrabackup_image_not_latest():
    """Test that backup image does not use 'latest' tag (security best practice)."""
    if not FLEET_RENDERED_MANIFEST or not os.path.exists(FLEET_RENDERED_MANIFEST):
        pytest.skip("Fleet rendered manifest not available")
    
    with open(FLEET_RENDERED_MANIFEST, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    # Find the PerconaXtraDBCluster custom resource
    pxc_cluster = None
    for doc in docs:
        if doc and doc.get('kind') == 'PerconaXtraDBCluster':
            pxc_cluster = doc
            break
    
    if not pxc_cluster:
        pytest.skip("PerconaXtraDBCluster resource not found in rendered manifest")
    
    backup_config = pxc_cluster.get('spec', {}).get('backup', {})
    if not backup_config:
        pytest.skip("No backup configuration found")
    
    backup_image = backup_config.get('image', '')
    
    if backup_image:
        image_tag = backup_image.split(':')[-1] if ':' in backup_image else ''
        
        log_check(
            criterion="Backup image tag must not be 'latest'",
            expected="!= latest",
            actual=image_tag,
            source=FLEET_RENDERED_MANIFEST
        )
        assert image_tag != 'latest', \
            f"Backup image should not use 'latest' tag, got: {backup_image}"


@pytest.mark.unit
def test_xtrabackup_image_format():
    """Test that backup image follows expected naming convention."""
    if not FLEET_RENDERED_MANIFEST or not os.path.exists(FLEET_RENDERED_MANIFEST):
        pytest.skip("Fleet rendered manifest not available")
    
    with open(FLEET_RENDERED_MANIFEST, 'r', encoding='utf-8') as f:
        docs = list(yaml.safe_load_all(f))
    
    # Find the PerconaXtraDBCluster custom resource
    pxc_cluster = None
    for doc in docs:
        if doc and doc.get('kind') == 'PerconaXtraDBCluster':
            pxc_cluster = doc
            break
    
    if not pxc_cluster:
        pytest.skip("PerconaXtraDBCluster resource not found in rendered manifest")
    
    backup_config = pxc_cluster.get('spec', {}).get('backup', {})
    if not backup_config:
        pytest.skip("No backup configuration found")
    
    backup_image = backup_config.get('image', '')
    
    if backup_image:
        # Backup image should be from Percona registry
        log_check(
            criterion="Backup image must be from percona/ repository",
            expected="starts with percona/",
            actual=backup_image,
            source=FLEET_RENDERED_MANIFEST
        )
        assert backup_image.startswith('percona/'), \
            f"Backup image should be from percona/ repository, got: {backup_image}"
        
        # Must include version tag
        log_check(
            criterion="Backup image must include version tag",
            expected="contains :",
            actual=backup_image,
            source=FLEET_RENDERED_MANIFEST
        )
        assert ':' in backup_image, \
            f"Backup image must include version tag, got: {backup_image}"

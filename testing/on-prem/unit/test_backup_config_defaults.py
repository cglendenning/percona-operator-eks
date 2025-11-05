import io
import os
import re
import yaml
from tests.conftest import log_check


def extract_backup_yaml_from_cluster_values(ts_source: str) -> str:
    """Extract the backup: YAML block from the clusterValues template literal in src/percona.ts.

    Returns the YAML text starting with 'backup:' and its nested content.
    """
    # Locate the start of the template literal returned by clusterValues
    m_start = re.search(r"function\s+clusterValues\([\s\S]*?return\s+`", ts_source)
    if not m_start:
        raise AssertionError("clusterValues template literal not found")

    start_idx = m_start.end()
    # Find the end backtick corresponding to the template
    m_end = re.search(r"\n`\;?\}\s*$", ts_source[start_idx:], re.MULTILINE)
    if not m_end:
        # Fallback: first closing backtick
        m_end = re.search(r"`", ts_source[start_idx:])
        if not m_end:
            raise AssertionError("clusterValues template literal closing backtick not found")
    end_idx = start_idx + m_end.start()

    yaml_text = ts_source[start_idx:end_idx]

    # Find the 'backup:' line at top-level (no leading spaces)
    lines = yaml_text.splitlines()
    backup_start = None
    for i, line in enumerate(lines):
        if re.match(r"^backup:\s*$", line):
            backup_start = i
            break
    if backup_start is None:
        raise AssertionError("backup: section not found in clusterValues YAML")

    # Capture lines until next top-level key (non-indented) or end of template
    captured = [lines[backup_start]]
    for line in lines[backup_start + 1 :]:
        if re.match(r"^[^\s]", line):
            break
        captured.append(line)

    return "\n".join(captured) + "\n"


def test_backup_configuration_defaults_match_source():
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    ts_file = os.path.join(project_root, "src", "percona.ts")

    with io.open(ts_file, "r", encoding="utf-8") as f:
        ts_source = f.read()

    backup_yaml = extract_backup_yaml_from_cluster_values(ts_source)

    # Load just the backup subtree for structural comparison
    loaded = yaml.safe_load(backup_yaml)

    # Expected structure — if any value changes, this test should fail
    expected = {
        "backup": {
            "enabled": True,
            "pitr": {
                "enabled": True,
                "storageName": "minio-backup",
                "timeBetweenUploads": 60,
            },
            "storages": {
                "minio-backup": {
                    "type": "s3",
                    "s3": {
                        "bucket": "percona-backups",
                        "region": "us-east-1",
                        "endpoint": "http://minio.minio.svc.cluster.local:9000",
                        "credentialsSecret": "percona-backup-minio-credentials",
                    },
                }
            },
            "schedule": [
                {
                    "name": "daily-backup",
                    "schedule": "0 2 * * *",
                    "retention": {
                        "type": "count",
                        "count": 7,
                        "deleteFromStorage": True,
                    },
                    "storageName": "minio-backup",
                },
                {
                    "name": "weekly-backup",
                    "schedule": "0 1 * * 0",
                    "retention": {
                        "type": "count",
                        "count": 8,
                        "deleteFromStorage": True,
                    },
                    "storageName": "minio-backup",
                },
                {
                    "name": "monthly-backup",
                    "schedule": "30 1 1 * *",
                    "retention": {
                        "type": "count",
                        "count": 12,
                        "deleteFromStorage": True,
                    },
                    "storageName": "minio-backup",
                },
            ],
        }
    }

    # Emit criterion/result comparison before assertion
    criterion = "Backup subtree in src/percona.ts must match expected default structure"
    expected_desc = "YAML structure matches expected keys and values"
    actual_desc = f"loaded keys={sorted(list(loaded.get('backup', {}).keys()))}"
    log_check(criterion=criterion, expected=expected_desc, actual=actual_desc, source=ts_file)

    assert loaded == expected, (
        "Backup configuration in src/percona.ts has changed.\n"
        "Update schedules/PITR/retention intentionally and adjust this test, or revert the change."
    )



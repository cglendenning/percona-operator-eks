"""
Test that Percona Helm repo is available
"""
import pytest
import subprocess
from rich.console import Console
from conftest import log_check

console = Console()

@pytest.mark.unit
def test_helm_repo_available():
    """Test that Percona Helm repo is available"""
    result = subprocess.run(
        ['helm', 'repo', 'list'],
        capture_output=True,
        text=True,
        check=True
    )

    present = 'percona' in result.stdout.lower()
    log_check(
        criterion="Helm repo list should include 'percona' repository",
        expected="present=True",
        actual=f"present={present}",
        source="helm repo list",
    )
    assert present, \
        "Percona Helm repo not found. Run: helm repo add percona https://percona.github.io/percona-helm-charts/"

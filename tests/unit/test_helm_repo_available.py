"""
Test that Percona Helm repo is available
"""
import pytest
import subprocess
from rich.console import Console

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

    assert 'percona' in result.stdout.lower(), \
        "Percona Helm repo not found. Run: helm repo add percona https://percona.github.io/percona-helm-charts/"

"""
Ensure the codebase is configured to use only the local ChartMuseum repo and
contains no references to external Helm repositories or raw URLs.
"""

import re
from pathlib import Path
from conftest import log_check


EXTERNAL_URL_PATTERNS = [
    r"https://percona\.github\.io/",
    r"https://charts\.min\.io/",
    r"https://litmuschaos\.github\.io/",
    r"https://raw\.githubusercontent\.com/",
]


def test_no_external_repo_urls_present_in_codebase():
    root = Path(__file__).resolve().parents[2]
    forbidden = []
    for path in root.rglob("*.*"):
        # Skip node_modules and venv
        if any(part in {"node_modules", "venv", "dist", "__pycache__"} for part in path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except Exception:
            continue
        for pat in EXTERNAL_URL_PATTERNS:
            if re.search(pat, text):
                forbidden.append((str(path), pat))
    log_check(
        criterion="Codebase should not contain references to external Helm/raw URLs",
        expected="none found",
        actual=f"violations={len(forbidden)}",
        source=str(root),
    )
    assert not forbidden, f"Found external URLs in code: {forbidden}"


def test_internal_repo_default_url_in_percona_ts():
    percona_ts = Path(__file__).resolve().parents[2] / "src" / "percona.ts"
    content = percona_ts.read_text(encoding="utf-8")
    present = "chartmuseum.chartmuseum.svc.cluster.local" in content
    log_check(
        criterion="percona.ts should default to internal ChartMuseum repo URL",
        expected="contains chartmuseum.chartmuseum.svc.cluster.local",
        actual=f"present={present}",
        source=str(percona_ts),
    )
    assert "chartmuseum.chartmuseum.svc.cluster.local" in content, (
        "percona.ts should default to internal ChartMuseum repo URL"
    )



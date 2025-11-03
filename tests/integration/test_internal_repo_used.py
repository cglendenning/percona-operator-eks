"""
Integration checks to ensure only the internal ChartMuseum repo is used.

Validates:
  - Helm repo list contains the internal repo and no well-known external repos
  - No CRDs were applied from external raw URLs (by scanning last-applied configs)
"""

import json
import subprocess


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def test_only_internal_helm_repo_present():
    result = run(["helm", "repo", "list", "--output", "json"])
    repos = json.loads(result.stdout)

    names = {r.get("name", "") for r in repos}
    urls = {r.get("url", "") for r in repos}

    assert any("chartmuseum" in (u or "") for u in urls), "Internal ChartMuseum repo not found in helm repo list"

    # Ensure common external repos are not present
    for forbidden in (
        "https://percona.github.io/percona-helm-charts/",
        "https://charts.min.io/",
        "https://litmuschaos.github.io/litmus-helm/",
    ):
        assert forbidden not in urls, f"External repo still configured: {forbidden}"


def test_no_crds_applied_from_external_urls():
    # Scan CRDs' last-applied-configuration for any external URL references
    crds = run(["kubectl", "get", "crd", "-o", "json"]).stdout
    data = json.loads(crds)
    for item in data.get("items", []):
        annotations = (item.get("metadata", {}).get("annotations", {}) or {})
        last_applied = annotations.get("kubectl.kubernetes.io/last-applied-configuration", "")
        assert "https://raw.githubusercontent.com" not in last_applied, (
            f"CRD {item['metadata']['name']} appears to be applied from external raw URL"
        )



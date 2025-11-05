"""
Unit tests for HAProxy configuration in Percona values.
Run by default (HAProxy-first environments). If --proxysql is set, these tests are skipped.
"""
import os
import pytest
from conftest import log_check, TOPOLOGY_KEY, get_values_for_test


@pytest.mark.unit
def test_haproxy_enabled(is_proxysql, values_norm):
    if is_proxysql:
        pytest.skip("Skipping HAProxy tests when --proxysql is set")

    values, path = get_values_for_test()

    haproxy = values.get('haproxy', {})
    if not isinstance(haproxy, dict) or haproxy.get('enabled') is not True:
        pytest.skip("HAProxy not enabled in this environment")
    log_check("haproxy.enabled should be true in HAProxy mode", "True", f"{haproxy.get('enabled')}", source=path)
    assert haproxy.get('enabled') is True


@pytest.mark.unit
def test_haproxy_pdb_and_affinity_if_present(is_proxysql):
    if is_proxysql:
        pytest.skip("Skipping HAProxy tests when --proxysql is set")

    values, path = get_values_for_test()

    haproxy = values.get('haproxy', {})
    if not isinstance(haproxy, dict) or haproxy.get('enabled') is not True:
        pytest.skip("HAProxy not enabled; skipping HAProxy-specific checks")

    # PDB checks if present
    if 'podDisruptionBudget' in haproxy:
        pdb = haproxy['podDisruptionBudget']
        max_unavailable = (pdb or {}).get('maxUnavailable')
        if max_unavailable is not None:
            log_check("HAProxy PDB maxUnavailable should be >= 0", ">= 0", f"{max_unavailable}", source=path)
            assert int(max_unavailable) >= 0

    # Anti-affinity checks if present (on-prem uses antiAffinityTopologyKey)
    affinity = haproxy.get('affinity') or {}
    if 'antiAffinityTopologyKey' in affinity:
        topology_key = affinity['antiAffinityTopologyKey']
        accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
        if TOPOLOGY_KEY == 'kubernetes.io/hostname':
            accepted_keys = ['kubernetes.io/hostname', 'topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
        log_check("HAProxy antiAffinityTopologyKey uses required topology key", f"in {accepted_keys}", f"{topology_key}", source=path)
        assert topology_key in accepted_keys, f"HAProxy antiAffinityTopologyKey must be in {accepted_keys}, got {topology_key}"
    elif 'podAntiAffinity' in affinity:
        pod_anti_affinity = affinity['podAntiAffinity']
        required = pod_anti_affinity.get('requiredDuringSchedulingIgnoredDuringExecution', [])
        if required:
            accepted_keys = ['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
            if TOPOLOGY_KEY == 'kubernetes.io/hostname':
                accepted_keys = ['kubernetes.io/hostname', 'topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone']
            topo_found = any((r.get('topologyKey') in accepted_keys) for r in required)
            log_check("HAProxy anti-affinity uses required topology key", f"in {accepted_keys}", f"found={topo_found}", source=path)
            assert topo_found


@pytest.mark.unit
def test_haproxy_resources_if_present(is_proxysql):
    if is_proxysql:
        pytest.skip("Skipping HAProxy tests when --proxysql is set")

    values, path = get_values_for_test()

    haproxy = values.get('haproxy', {})
    if not isinstance(haproxy, dict) or haproxy.get('enabled') is not True:
        pytest.skip("HAProxy not enabled; skipping HAProxy-specific checks")

    resources = haproxy.get('resources') or {}
    if resources:
        # Only assert presence/structure if defined in values
        req = resources.get('requests') or {}
        lim = resources.get('limits') or {}
        log_check("haproxy resources.requests present", "dict", f"{bool(req)}", source=path)
        log_check("haproxy resources.limits present", "dict", f"{bool(lim)}", source=path)
        assert isinstance(req, dict)
        assert isinstance(lim, dict)



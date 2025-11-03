# Disaster Recovery Test Structure

This document describes the structure and validation of DR scenario tests.

## Overview

DR scenarios are defined in `disaster_scenarios/disaster_scenarios.json` with corresponding individual test files in `tests/resiliency/`.

## JSON Structure

Each scenario in `disaster_scenarios.json` must have the following fields:

### Required Original Fields
- `scenario`: Name of the DR scenario
- `primary_recovery_method`: Primary recovery approach
- `alternate_fallback`: Alternative recovery method
- `detection_signals`: How to detect this issue
- `rto_target`: Recovery Time Objective target
- `rpo_target`: Recovery Point Objective target
- `mttr_expected`: Mean Time To Recovery expected
- `expected_data_loss`: Expected data loss description
- `likelihood`: Likelihood of occurrence (Low/Medium/High)
- `business_impact`: Business impact level (Low/Medium/High/Critical)
- `affected_components`: Components affected by this scenario
- `notes_assumptions`: Additional notes and assumptions

### Required Test Fields
- `test_enabled`: Boolean indicating if automated testing is possible
- `test_file`: Filename of the test (or `null` if `test_enabled=false`)
- `test_description`: Description of why test is/isn't automated

### Test Automation Fields (required if `test_enabled=true`)
- `chaos_type`: Type of chaos to inject (e.g., "pod-delete", "node-drain")
- `target_label`: Kubernetes label selector for target resources
- `app_kind`: Kubernetes resource kind (e.g., "statefulset", "deployment")
- `expected_recovery`: Type of recovery verification ("cluster_ready", "statefulset_ready", "service_endpoints", "pods_running")
- `mttr_seconds`: Maximum time allowed for recovery
- `poll_interval`: Seconds between recovery checks
- `total_chaos_duration`: Total duration chaos runs
- `chaos_interval`: Interval between chaos events

## Test File Naming Convention

Test files must follow this pattern:
- Filename: `test_dr_<scenario_name_normalized>.py`
- Located in: `tests/resiliency/`
- Must start with: `test_dr_`
- Must end with: `.py`

Example: "Single MySQL pod failure" → `test_dr_single_mysql_pod_failure.py`

## Validation

The `test_dr_coverage.py` file contains validation tests that ensure:

1. All scenarios have the `test_file` field defined
2. Enabled scenarios (`test_enabled=true`) have corresponding test files
3. Disabled scenarios (`test_enabled=false`) have `test_file=null`
4. No orphaned test files exist (files without JSON entries)
5. Test files follow naming conventions

## Current Coverage

- **Total Scenarios**: 16
- **With Automated Tests**: 4 (25%)
- **Explicitly No Test**: 12 (75%)

### Scenarios With Automated Tests

1. Single MySQL pod failure - `test_dr_single_mysql_pod_failure.py`
2. Kubernetes worker node failure - `test_dr_kubernetes_worker_node_failure.py`
3. Percona Operator misconfiguration - `test_dr_percona_operator_crd_misconfiguration.py`
4. Ingress/VIP failure - `test_dr_ingressvip_failure.py`

### Scenarios Without Automated Tests

12 scenarios are explicitly marked as `test_enabled=false` because they require multi-DC infrastructure, destructive operations, or are covered by other tests.

## Adding a New DR Scenario

1. Add entry to `disaster_scenarios.json` with all required fields
2. Create test file at `tests/resiliency/test_dr_<name>.py`
3. Run validation: `pytest tests/resiliency/test_dr_coverage.py -v`

## If Test is Not Possible

Set `test_enabled: false` and `test_file: null`, with explanation in `test_description`.

## Benefits

1. **Traceability**: Every DR scenario is tracked
2. **Visibility**: Easy to see test coverage
3. **Enforcement**: Validation prevents scenarios without explicit test status
4. **Maintainability**: Individual test files
5. **Documentation**: Tests serve as executable documentation

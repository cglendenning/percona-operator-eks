"""
Disaster Recovery Test Coverage Validation

This test ensures that every DR scenario in disaster_scenarios.json has:
1. A corresponding test file in tests/resiliency/ (if test_enabled=true)
2. Explicitly set test_file=null (if test_enabled=false)

This prevents scenarios from being added without proper test coverage or
explicit acknowledgment that no test exists.
"""
import json
import os
import pytest
from pathlib import Path


# Path to DR scenarios JSON file
SCENARIOS_FILE = Path(__file__).parent.parent.parent / 'disaster_scenarios' / 'disaster_scenarios.json'
RESILIENCY_DIR = Path(__file__).parent


def load_dr_scenarios():
    """Load disaster recovery scenarios from JSON"""
    with open(SCENARIOS_FILE, 'r') as f:
        return json.load(f)


@pytest.mark.unit
def test_dr_scenarios_json_exists():
    """Verify the disaster_scenarios.json file exists"""
    assert SCENARIOS_FILE.exists(), f"DR scenarios JSON file not found: {SCENARIOS_FILE}"


@pytest.mark.unit
def test_dr_scenarios_json_valid():
    """Verify the disaster_scenarios.json is valid JSON"""
    try:
        scenarios = load_dr_scenarios()
        assert isinstance(scenarios, list), "DR scenarios must be a list"
        assert len(scenarios) > 0, "DR scenarios list cannot be empty"
    except json.JSONDecodeError as e:
        pytest.fail(f"Invalid JSON in disaster_scenarios.json: {e}")


@pytest.mark.unit
def test_all_scenarios_have_test_file_field():
    """Verify all scenarios have the test_file field defined"""
    scenarios = load_dr_scenarios()
    
    missing_field = []
    for i, scenario in enumerate(scenarios, 1):
        scenario_name = scenario.get('scenario', f'<unnamed scenario {i}>')
        if 'test_file' not in scenario:
            missing_field.append(scenario_name)
    
    assert not missing_field, (
        f"The following scenarios are missing the 'test_file' field:\n"
        f"  {', '.join(missing_field)}\n\n"
        f"Every scenario must have either:\n"
        f"  - test_file: 'test_dr_*.py' (if test_enabled=true)\n"
        f"  - test_file: null (if test_enabled=false)"
    )


@pytest.mark.unit
def test_enabled_scenarios_have_test_files():
    """Verify that enabled scenarios have corresponding test files"""
    scenarios = load_dr_scenarios()
    
    missing_tests = []
    invalid_tests = []
    
    for scenario in scenarios:
        scenario_name = scenario.get('scenario', '<unnamed>')
        test_enabled = scenario.get('test_enabled', False)
        test_file = scenario.get('test_file')
        
        if test_enabled:
            # Enabled scenarios must have a test_file
            if not test_file:
                missing_tests.append({
                    'scenario': scenario_name,
                    'issue': 'test_enabled=true but test_file is null or missing'
                })
            else:
                # Check if test file exists
                test_path = RESILIENCY_DIR / test_file
                if not test_path.exists():
                    missing_tests.append({
                        'scenario': scenario_name,
                        'issue': f'test file does not exist: {test_file}'
                    })
                elif not test_file.startswith('test_dr_'):
                    invalid_tests.append({
                        'scenario': scenario_name,
                        'issue': f'test file must start with "test_dr_": {test_file}'
                    })
                elif not test_file.endswith('.py'):
                    invalid_tests.append({
                        'scenario': scenario_name,
                        'issue': f'test file must end with ".py": {test_file}'
                    })
    
    errors = []
    if missing_tests:
        errors.append("Scenarios with test_enabled=true but missing or invalid test files:")
        for item in missing_tests:
            errors.append(f"  • {item['scenario']}")
            errors.append(f"    {item['issue']}")
    
    if invalid_tests:
        errors.append("\nScenarios with invalid test file names:")
        for item in invalid_tests:
            errors.append(f"  • {item['scenario']}")
            errors.append(f"    {item['issue']}")
    
    assert not errors, "\n".join(errors)


@pytest.mark.unit
def test_disabled_scenarios_have_null_test_file():
    """Verify that disabled scenarios explicitly have test_file=null"""
    scenarios = load_dr_scenarios()
    
    issues = []
    
    for scenario in scenarios:
        scenario_name = scenario.get('scenario', '<unnamed>')
        test_enabled = scenario.get('test_enabled', False)
        test_file = scenario.get('test_file')
        
        if not test_enabled:
            # Disabled scenarios must have test_file=null (explicit)
            if test_file is not None:
                issues.append({
                    'scenario': scenario_name,
                    'issue': f'test_enabled=false but test_file is not null: {test_file}'
                })
    
    if issues:
        error_msg = ["Scenarios with test_enabled=false must have test_file=null:"]
        for item in issues:
            error_msg.append(f"  • {item['scenario']}")
            error_msg.append(f"    {item['issue']}")
        pytest.fail("\n".join(error_msg))


@pytest.mark.unit
def test_no_orphaned_dr_test_files():
    """Verify all test_dr_*.py files have corresponding scenarios in JSON"""
    scenarios = load_dr_scenarios()
    
    # Get all test files from JSON
    expected_test_files = {
        scenario.get('test_file') 
        for scenario in scenarios 
        if scenario.get('test_file')
    }
    
    # Get all actual test_dr_*.py files in resiliency directory
    actual_test_files = {
        f.name 
        for f in RESILIENCY_DIR.glob('test_dr_*.py')
        if f.name != 'test_dr_scenarios.py' and f.name != 'test_dr_coverage.py'
    }
    
    # Find orphaned files (exist but not in JSON)
    orphaned = actual_test_files - expected_test_files
    
    assert not orphaned, (
        f"Found orphaned DR test files not referenced in disaster_scenarios.json:\n"
        f"  {', '.join(sorted(orphaned))}\n\n"
        f"Either:\n"
        f"  1. Add these files to a scenario's test_file field in disaster_scenarios.json\n"
        f"  2. Remove these files if they're no longer needed"
    )


@pytest.mark.unit
def test_dr_coverage_summary():
    """Display DR test coverage summary"""
    scenarios = load_dr_scenarios()
    
    total = len(scenarios)
    tested = sum(1 for s in scenarios if s.get('test_enabled'))
    not_tested = sum(1 for s in scenarios if not s.get('test_enabled'))
    coverage_pct = (tested / total * 100) if total > 0 else 0
    
    print("\n" + "=" * 80)
    print("DR TEST COVERAGE SUMMARY")
    print("=" * 80)
    print(f"Total scenarios: {total}")
    print(f"Tested scenarios: {tested} ({coverage_pct:.1f}%)")
    print(f"Explicitly no test: {not_tested}")
    print()
    
    if not_tested > 0:
        print("Scenarios without tests (test_enabled=false):")
        for scenario in scenarios:
            if not scenario.get('test_enabled'):
                print(f"  • {scenario['scenario']}")
                reason = scenario.get('test_description', 'No reason provided')
                print(f"    Reason: {reason}")
        print()
    
    print("Scenarios with tests:")
    for scenario in scenarios:
        if scenario.get('test_enabled'):
            print(f"  ✓ {scenario['scenario']}")
            print(f"    Test: {scenario.get('test_file')}")
    
    print("=" * 80)
    
    # This test always passes - it's just for reporting
    assert True


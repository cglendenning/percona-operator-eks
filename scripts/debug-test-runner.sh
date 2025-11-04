#!/bin/bash
# Debug script to diagnose run_tests.sh issues
# Run this to see exactly where the script is failing

echo "===== Python Test Runner Diagnostics ====="
echo ""

# Check Python
echo "1. Python Check:"
echo "   python3 version: $(python3 --version 2>&1)"
echo "   python3 location: $(which python3)"
echo "   python3.14 available: $(command -v python3.14 >/dev/null 2>&1 && echo 'Yes' || echo 'No')"
if command -v python3.14 >/dev/null 2>&1; then
    echo "   python3.14 version: $(python3.14 --version 2>&1)"
fi
echo ""

# Check venv
echo "2. Virtual Environment Check:"
if [ -d "venv" ]; then
    echo "   venv exists: Yes"
    echo "   venv Python: $(venv/bin/python --version 2>&1)"
    echo "   venv pip: $(venv/bin/pip --version 2>&1 | head -1)"
else
    echo "   venv exists: No"
fi
echo ""

# Check kubectl
echo "3. Kubernetes Check:"
if command -v kubectl >/dev/null 2>&1; then
    echo "   kubectl available: Yes"
    if kubectl cluster-info >/dev/null 2>&1; then
        echo "   kubectl connected: Yes"
        echo "   Current context: $(kubectl config current-context 2>/dev/null || echo 'unknown')"
    else
        echo "   kubectl connected: No (THIS MIGHT BE THE ISSUE)"
        echo "   Error: $(kubectl cluster-info 2>&1 | head -1)"
    fi
else
    echo "   kubectl available: No (THIS IS THE ISSUE)"
fi
echo ""

# Check namespace
echo "4. Namespace Check:"
TEST_NAMESPACE=${TEST_NAMESPACE:-percona}
echo "   Looking for namespace: $TEST_NAMESPACE"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    if kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
        echo "   Namespace exists: Yes"
    else
        echo "   Namespace exists: No (tests will fail but script should continue)"
    fi
else
    echo "   Cannot check (kubectl not working)"
fi
echo ""

# Check test files
echo "5. Test Files Check:"
echo "   Unit tests: $(find tests/unit -name 'test_*.py' 2>/dev/null | wc -l) files"
echo "   Integration tests: $(find tests/integration -name 'test_*.py' 2>/dev/null | wc -l) files"
echo "   Resiliency tests: $(find tests/resiliency -name 'test_*.py' 2>/dev/null | wc -l) files"
echo ""

# Check pytest
echo "6. Pytest Check:"
if [ -d "venv" ]; then
    source venv/bin/activate
    if command -v pytest >/dev/null 2>&1; then
        echo "   pytest available: Yes"
        echo "   pytest version: $(pytest --version 2>&1 | head -1)"
        echo ""
        echo "7. Trying to collect tests:"
        echo "   Collecting unit tests..."
        pytest tests/unit --collect-only -q 2>&1 | head -20
    else
        echo "   pytest available: No (THIS IS THE ISSUE)"
        echo "   Try: pip install -r tests/requirements.txt"
    fi
    deactivate
else
    echo "   Cannot check (venv doesn't exist)"
fi
echo ""

echo "===== Diagnostics Complete ====="
echo ""
echo "Common Issues:"
echo "  1. If kubectl is not connected, run_tests.sh will exit early"
echo "  2. If pytest is not installed, tests won't run"
echo "  3. If no test files found, check you're in the right directory"
echo ""


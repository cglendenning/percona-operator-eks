#!/usr/bin/env bash
#
# Minimal test runner - assertions defined in Nix
#
set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
TOTAL=0

# Ensure test pod exists before running connectivity tests
ensure_test_pod() {
  local ctx="k3d-cluster-b"
  if ! kubectl get pod test-pod -n demo --context="$ctx" &>/dev/null; then
    echo -e "${BLUE}Creating test pod in Cluster B...${NC}"
    kubectl delete pod test-pod -n demo --context="$ctx" 2>/dev/null || true
    kubectl run test-pod --image=curlimages/curl --context="$ctx" -n demo -- sleep 3600
    kubectl wait --for=condition=ready pod/test-pod -n demo --context="$ctx" --timeout=120s
    echo ""
  fi
}

# Run a single assertion
run_assertion() {
  local id="$1"
  local description="$2"
  local command="$3"
  local type="$4"
  local pattern="${5:-}"
  
  TOTAL=$((TOTAL + 1))
  printf "[%2d] %-60s" "$TOTAL" "$description"
  
  if [ "$type" = "exit-code" ]; then
    if eval "$command" &>/dev/null; then
      echo -e "${GREEN}✓${NC}"
      PASSED=$((PASSED + 1))
      return 0
    else
      echo -e "${RED}✗${NC}"
      FAILED=$((FAILED + 1))
      return 1
    fi
  elif [ "$type" = "pattern-match" ]; then
    output=$(eval "$command" 2>&1 || echo "")
    if echo "$output" | grep -qE "$pattern"; then
      echo -e "${GREEN}✓${NC}"
      PASSED=$((PASSED + 1))
      return 0
    else
      echo -e "${RED}✗${NC}"
      FAILED=$((FAILED + 1))
      return 1
    fi
  fi
}

# Get assertion data from Nix
get_assertions() {
  local category="$1"
  nix eval --json ".#lib.testAssertions.${category}" 2>/dev/null || echo "[]"
}

# Get category metadata
get_category_name() {
  local category="$1"
  nix eval --raw ".#lib.testAssertions.categories.${category}.name" 2>/dev/null || echo "$category"
}

# Main test execution
main() {
  echo "=========================================="
  echo "Multi-Cluster Istio Test Suite"
  echo "Assertions defined in: lib/test-assertions.nix"
  echo "=========================================="
  echo ""

  # Ensure test pod exists before connectivity tests
  ensure_test_pod

  # Test categories in order
  categories=(
    "infrastructure"
    "controlPlane"
    "mtls"
    "multiClusterConfig"
    "application"
    "connectivity"
    "endToEnd"
  )

  for category in "${categories[@]}"; do
    category_name=$(get_category_name "$category")
    echo ""
    echo -e "${BLUE}=== $category_name ===${NC}"
    echo ""
    
    # Get assertions for this category
    assertions=$(get_assertions "$category")
    
    # Parse and run each assertion
    length=$(echo "$assertions" | jq -r 'length')
    for ((i=0; i<length; i++)); do
      id=$(echo "$assertions" | jq -r ".[$i].id")
      description=$(echo "$assertions" | jq -r ".[$i].description")
      command=$(echo "$assertions" | jq -r ".[$i].command")
      type=$(echo "$assertions" | jq -r ".[$i].type")
      pattern=$(echo "$assertions" | jq -r ".[$i].expectedPattern // empty")
      
      run_assertion "$id" "$description" "$command" "$type" "$pattern"
    done
  done

  # Summary
  echo ""
  echo "=========================================="
  echo "TEST SUMMARY"
  echo "=========================================="
  echo ""
  echo "Total Assertions: $TOTAL"
  echo -e "Passed: ${GREEN}$PASSED${NC}"
  echo -e "Failed: ${RED}$FAILED${NC}"
  echo ""

  if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed! Multi-cluster Istio is working correctly.${NC}"
    exit 0
  else
    echo -e "${RED}✗ Some tests failed. Review the output above for details.${NC}"
    exit 1
  fi
}

main "$@"

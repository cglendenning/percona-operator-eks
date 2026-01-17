#!/usr/bin/env bash
#
# Minimal test runner - assertions defined in Nix
#
set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
TOTAL=0

# Ensure test pod exists before running connectivity tests
ensure_test_pod() {
  local ctx="k3d-cluster-b"
  local ns="wookie-dr"
  if ! kubectl get pod test-pod -n "$ns" --context="$ctx" &>/dev/null; then
    echo -e "${BLUE}Creating test pod in Cluster B ($ns namespace)...${NC}"
    kubectl delete pod test-pod -n "$ns" --context="$ctx" 2>/dev/null || true
    kubectl run test-pod --image=curlimages/curl --context="$ctx" -n "$ns" -- sleep 3600
    kubectl wait --for=condition=ready pod/test-pod -n "$ns" --context="$ctx" --timeout=120s
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
    output=$(eval "$command" 2>&1 || true)
    # Check if pattern exists in output (use count instead of -q for reliability)
    match_count=$(echo "$output" | grep -c "$pattern" || echo "0")
    if [ "$match_count" -gt 0 ]; then
      echo -e "${GREEN}✓${NC}"
      PASSED=$((PASSED + 1))
      return 0
    else
      echo -e "${RED}✗${NC}"
      FAILED=$((FAILED + 1))
      # Show first 100 chars of output for debugging critical failures
      if [[ "$id" == "cross-cluster-http" ]] || [[ "$id" == "mtls-enabled" ]]; then
        echo "       Error: ${output:0:100}"
      fi
      return 1
    fi
  fi
}

# Detect system
get_system() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "aarch64-darwin" ;;
    Darwin-x86_64) echo "x86_64-darwin" ;;
    Linux-x86_64) echo "x86_64-linux" ;;
    Linux-aarch64) echo "aarch64-linux" ;;
    *) echo "x86_64-linux" ;;
  esac
}

SYSTEM=$(get_system)

# Get assertion data from Nix
get_assertions() {
  local category="$1"
  local result
  # Capture stderr and stdout separately, then filter out warnings
  result=$(nix eval --json ".#lib.${SYSTEM}.testAssertions.${category}" 2>&1 | grep -v "^warning:")
  local exit_code=$?
  if [ $exit_code -eq 0 ] && echo "$result" | jq -e . >/dev/null 2>&1; then
    echo "$result"
  else
    echo "ERROR: Failed to get assertions for $category" >&2
    echo "[]"
  fi
}

# Get category metadata
get_category_name() {
  local category="$1"
  nix eval --raw ".#lib.${SYSTEM}.testAssertions.categories.${category}.name" 2>&1 | grep -v "^warning:" || echo "$category"
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
    "dynamicDiscovery"
    "cleanup"
  )

  for category in "${categories[@]}"; do
    category_name=$(get_category_name "$category")
echo ""
    echo -e "${BLUE}=== $category_name ===${NC}"
echo ""

    # Get assertions for this category
    assertions=$(get_assertions "$category")
    
    # Debug: show what we got
    if [ "$assertions" = "[]" ] || [ -z "$assertions" ]; then
      echo -e "${RED}ERROR: No assertions loaded for category '$category'${NC}"
      echo "Tried to query: .#lib.${SYSTEM}.testAssertions.${category}"
      continue
    fi
    
    # Parse and run each assertion
    length=$(echo "$assertions" | jq -r 'length')
    for ((i=0; i<length; i++)); do
      id=$(echo "$assertions" | jq -r ".[$i].id")
      description=$(echo "$assertions" | jq -r ".[$i].description")
      command=$(echo "$assertions" | jq -r ".[$i].command")
      type=$(echo "$assertions" | jq -r ".[$i].type")
      pattern=$(echo "$assertions" | jq -r ".[$i].expectedPattern // empty")
      
      # Run assertion and continue on failure (don't exit due to set -e)
      run_assertion "$id" "$description" "$command" "$type" "$pattern" || true
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

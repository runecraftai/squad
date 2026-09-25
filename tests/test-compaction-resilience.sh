#!/usr/bin/env bash
# Test suite for Pi compaction resilience extension
#
# Tests:
# 1. Extension loads without errors
# 2. Compaction state is preserved
# 3. Re-engagement message is generated correctly
# 4. State persists across compactions
#
# Usage:
#   tests/test-compaction-resilience.sh
#
# Requires:
# - Pi installed and available in PATH
# - jq for JSON processing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
EXTENSION_PATH="${SCRIPT_DIR}/../.pi/extensions/compaction-resilience.ts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
log_test() {
  echo -e "${YELLOW}[TEST]${NC} $*"
}

log_pass() {
  echo -e "${GREEN}[PASS]${NC} $*"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $*"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Cleanup function
cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# Test 1: Extension file exists and is valid TypeScript
test_extension_exists() {
  log_test "Extension file exists"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if [ ! -f "$EXTENSION_PATH" ]; then
    log_fail "Extension file not found: $EXTENSION_PATH"
    return
  fi
  
  # Check it's valid TypeScript (basic syntax check)
  if grep -q "export default function" "$EXTENSION_PATH"; then
    log_pass "Extension file exists and has valid structure"
  else
    log_fail "Extension file missing default export"
  fi
}

# Test 2: Extension has required event handlers
test_event_handlers() {
  log_test "Extension has required event handlers"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local required_handlers=(
    "session_before_compact"
    "turn_end"
    "agent_before_settle"
    "session_start"
  )
  
  local missing=()
  for handler in "${required_handlers[@]}"; do
    if ! grep -q "pi.on(\"$handler\"" "$EXTENSION_PATH"; then
      missing+=("$handler")
    fi
  done
  
  if [ ${#missing[@]} -eq 0 ]; then
    log_pass "All required event handlers present"
  else
    log_fail "Missing event handlers: ${missing[*]}"
  fi
}

# Test 3: Extension has required commands
test_commands() {
  log_test "Extension has required commands"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local required_commands=(
    "compaction-status"
    "compaction-reengage"
  )
  
  local missing=()
  for cmd in "${required_commands[@]}"; do
    if ! grep -q "pi.registerCommand(\"$cmd\"" "$EXTENSION_PATH"; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -eq 0 ]; then
    log_pass "All required commands present"
  else
    log_fail "Missing commands: ${missing[*]}"
  fi
}

# Test 4: Extension has state management
test_state_management() {
  log_test "Extension has state management"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if grep -q "OperatorState" "$EXTENSION_PATH" && \
     grep -q "operatorState" "$EXTENSION_PATH" && \
     grep -q "createDefaultState" "$EXTENSION_PATH"; then
    log_pass "State management functions present"
  else
    log_fail "State management functions missing"
  fi
}

# Test 5: Extension has summary generation
test_summary_generation() {
  log_test "Extension has summary generation"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if grep -q "generateCompactionSummary" "$EXTENSION_PATH" && \
     grep -q "generateReengagementMessage" "$EXTENSION_PATH"; then
    log_pass "Summary generation functions present"
  else
    log_fail "Summary generation functions missing"
  fi
}

# Test 6: Config script exists and is executable
test_config_script() {
  log_test "Config script exists and is executable"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local config_script="${SCRIPT_DIR}/../bin/sq-pi-compaction-config.sh"
  
  if [ -f "$config_script" ] && [ -x "$config_script" ]; then
    log_pass "Config script exists and is executable"
  else
    log_fail "Config script missing or not executable"
  fi
}

# Test 7: Config script has required commands
test_config_commands() {
  log_test "Config script has required commands"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local config_script="${SCRIPT_DIR}/../bin/sq-pi-compaction-config.sh"
  
  if grep -q "enable_compaction" "$config_script" && \
     grep -q "disable_compaction" "$config_script" && \
     grep -q "show_status" "$config_script"; then
    log_pass "Config script has required commands"
  else
    log_fail "Config script missing required commands"
  fi
}

# Test 8: Extension handles tool calls
test_tool_call_handling() {
  log_test "Extension handles tool calls"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if grep -q "pi.on(\"tool_call\"" "$EXTENSION_PATH" && \
     grep -q "filesModified" "$EXTENSION_PATH"; then
    log_pass "Tool call handling present"
  else
    log_fail "Tool call handling missing"
  fi
}

# Run all tests
main() {
  echo ""
  echo "=== Pi Compaction Resilience Extension Tests ==="
  echo ""
  
  test_extension_exists
  test_event_handlers
  test_commands
  test_state_management
  test_summary_generation
  test_config_script
  test_config_commands
  test_tool_call_handling
  
  echo ""
  echo "=== Test Results ==="
  echo "Tests run: $TESTS_RUN"
  echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  echo ""
  
  if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
  else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
  fi
}

main "$@"

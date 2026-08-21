#!/usr/bin/env bash
# Tests for sq-register-package-skills.sh
#
# Tests:
#   1. Fresh setup: skills are registered correctly
#   2. Repeat setup: idempotent behavior
#   3. Missing package: graceful handling
#   4. --check flag: reports without modifying
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER_SCRIPT="$SQUAD_ROOT/bin/sq-register-package-skills.sh"

# Test utilities
test_count=0
pass_count=0
fail_count=0

setup() {
  # Create temporary test directory
  TEST_DIR=$(mktemp -d)
  export SQUAD_ROOT_OVERRIDE="$TEST_DIR"
  
  # Create minimal package structure
  mkdir -p "$TEST_DIR/packages/test-pkg/skills/test-skill"
  cat > "$TEST_DIR/packages/test-pkg/skills/test-skill/SKILL.md" << 'EOF'
---
name: test-skill
description: A test skill for unit testing
---
# Test Skill
This is a test skill.
EOF
  
  # Create skills directory
  mkdir -p "$TEST_DIR/skills"

  mkdir -p "$TEST_DIR/packages/test-pkg/manifest-skill"
  cat > "$TEST_DIR/packages/test-pkg/manifest-skill/SKILL.md" << 'EOF'
---
name: manifest-skill
description: A manifest-discovered skill
---
# Manifest Skill
EOF
  cat > "$TEST_DIR/packages/test-pkg/package.json" << 'EOF'
{"name":"test-pkg","pi":{"skills":["manifest-skill"]}}
EOF
}

cleanup() {
  rm -rf "$TEST_DIR"
  unset SQUAD_ROOT_OVERRIDE
}

assert_equals() {
  local expected="$1" actual="$2" message="${3:-}"
  test_count=$((test_count + 1))
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
    if [ -n "$message" ]; then
      echo "PASS: $message"
    fi
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: ${message:-assertion failed}"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_exists() {
  local path="$1" message="${2:-}"
  test_count=$((test_count + 1))
  if [ -e "$path" ] || [ -L "$path" ]; then
    pass_count=$((pass_count + 1))
    if [ -n "$message" ]; then
      echo "PASS: $message"
    fi
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: ${message:-path does not exist: $path}"
  fi
}

assert_not_exists() {
  local path="$1" message="${2:-}"
  test_count=$((test_count + 1))
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    pass_count=$((pass_count + 1))
    if [ -n "$message" ]; then
      echo "PASS: $message"
    fi
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: ${message:-path exists: $path}"
  fi
}

# Test 1: Fresh setup
test_fresh_setup() {
  echo "=== Test 1: Fresh setup ==="
  setup
  
  # Run registration
  output=$("$REGISTER_SCRIPT" 2>&1) || true
  
  # Check that skill was registered
  assert_exists "$TEST_DIR/skills/test-skill" "skill symlink created"
  
  # Check that symlink points to correct directory
  if [ -L "$TEST_DIR/skills/test-skill" ]; then
    target=$(readlink "$TEST_DIR/skills/test-skill")
    assert_equals "$TEST_DIR/packages/test-pkg/skills/test-skill" "$target" "symlink points to correct directory"
  fi
  assert_exists "$TEST_DIR/skills/manifest-skill" "manifest skill symlink created"
  assert_equals "$TEST_DIR/packages/test-pkg/manifest-skill" "$(readlink "$TEST_DIR/skills/manifest-skill")" "manifest symlink points to package skill"

  cleanup
}

# Test 2: Repeat setup (idempotent)
test_repeat_setup() {
  echo "=== Test 2: Repeat setup ==="
  setup
  
  # Run registration twice
  "$REGISTER_SCRIPT" >/dev/null 2>&1 || true
  output=$("$REGISTER_SCRIPT" 2>&1) || true
  
  # Check that skill still exists and is correct
  assert_exists "$TEST_DIR/skills/test-skill" "skill symlink still exists after repeat"
  
  if [ -L "$TEST_DIR/skills/test-skill" ]; then
    target=$(readlink "$TEST_DIR/skills/test-skill")
    assert_equals "$TEST_DIR/packages/test-pkg/skills/test-skill" "$target" "symlink unchanged after repeat"
  fi
  
  cleanup
}

# Test 3: Missing package
test_missing_package() {
  echo "=== Test 3: Missing package ==="
  setup
  
  "$REGISTER_SCRIPT" >/dev/null 2>&1
  rm -rf "$TEST_DIR/packages/test-pkg"

  output=$("$REGISTER_SCRIPT" 2>&1) || true

  assert_not_exists "$TEST_DIR/skills/test-skill" "stale conventional skill removed"
  assert_not_exists "$TEST_DIR/skills/manifest-skill" "stale manifest skill removed"
  
  cleanup
}

# Test 4: --check flag
test_check_flag() {
  echo "=== Test 4: --check flag ==="
  setup
  
  # Run with --check
  output=$("$REGISTER_SCRIPT" --check 2>&1) || true
  
  # Check that no symlink was created
  assert_not_exists "$TEST_DIR/skills/test-skill" "no symlink created with --check"
  
  # Check that output reports what would be registered
  if echo "$output" | grep -q "would register"; then
    test_count=$((test_count + 1))
    pass_count=$((pass_count + 1))
    echo "PASS: --check reports what would be registered"
  else
    test_count=$((test_count + 1))
    fail_count=$((fail_count + 1))
    echo "FAIL: --check did not report what would be registered"
  fi
  
  cleanup
}

# Test 5: Multiple packages
test_multiple_packages() {
  echo "=== Test 5: Multiple packages ==="
  setup
  
  # Create second package
  mkdir -p "$TEST_DIR/packages/another-pkg/skills/another-skill"
  cat > "$TEST_DIR/packages/another-pkg/skills/another-skill/SKILL.md" << 'EOF'
---
name: another-skill
description: Another test skill
---
# Another Skill
EOF
  
  # Run registration
  output=$("$REGISTER_SCRIPT" 2>&1) || true
  
  # Check that both skills were registered
  assert_exists "$TEST_DIR/skills/test-skill" "first skill registered"
  assert_exists "$TEST_DIR/skills/another-skill" "second skill registered"
  
  cleanup
}

# Test 6: Existing directory (user-created skill)
test_existing_directory() {
  echo "=== Test 6: Existing directory ==="
  setup
  
  # Create existing skill directory
  mkdir -p "$TEST_DIR/skills/test-skill"
  
  # Run registration - should not overwrite
  output=$("$REGISTER_SCRIPT" 2>&1) || true
  
  # Check that existing directory was preserved
  if [ -d "$TEST_DIR/skills/test-skill" ] && [ ! -L "$TEST_DIR/skills/test-skill" ]; then
    test_count=$((test_count + 1))
    pass_count=$((pass_count + 1))
    echo "PASS: existing directory preserved"
  else
    test_count=$((test_count + 1))
    fail_count=$((fail_count + 1))
    echo "FAIL: existing directory was overwritten"
  fi
  
  cleanup
}

# Run all tests
test_fresh_setup
test_repeat_setup
test_missing_package
test_check_flag
test_multiple_packages
test_existing_directory

# Summary
echo ""
echo "=== Test Summary ==="
echo "Total: $test_count"
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0

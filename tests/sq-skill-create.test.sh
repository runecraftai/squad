#!/usr/bin/env bash
# Behavioral regressions for sq-skill-create.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/sq-skill-create.sh"
TMP_ROOT=$(fm_test_tmproot sq-skill-create)

test_usage_no_args() {
  local out rc=0
  out=$("$SCRIPT" 2>&1) || rc=$?
  expect_code 2 "$rc" "no-args exits 2"
  assert_contains "$out" "usage:" "no-args prints usage"
  pass "prints usage and exits 2 with no arguments"
}

test_usage_help_flag() {
  local out rc=0
  out=$("$SCRIPT" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "usage:" "--help prints usage"
  pass "--help prints usage and exits 0"
}

test_unknown_flag() {
  local out rc=0
  out=$("$SCRIPT" "test" --bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown flag exits 2"
  assert_contains "$out" "unknown flag" "unknown flag prints error"
  pass "rejects unknown flags"
}

test_generation_and_validation() {
  local dir out rc=0
  dir="$TMP_ROOT/gen"
  mkdir -p "$dir"
  out=$("$SCRIPT" "Monitor disk usage across servers" \
    --name disk-monitor --dir "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "generation succeeds"
  assert_contains "$out" "Format validation: PASSED" "format validation passes"
  assert_contains "$out" "Trigger validation: PASSED" "trigger validation passes"
  pass "generated skill passes format and trigger validation"
}

test_auto_derived_name() {
  local dir out rc=0
  dir="$TMP_ROOT/autoname"
  mkdir -p "$dir"
  out=$($SCRIPT "Check SSL certificate expiry dates" --dir "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "auto-name succeeds"
  # The auto-derived name should contain "check" or "ssl" from the description.
  assert_contains "$out" "Format validation: PASSED" "auto-named skill validates"
  pass "auto-derives a skill name from description"
}

test_approve_copies_skill() {
  local target out rc=0
  target="$TMP_ROOT/approved"
  mkdir -p "$target"
  out=$("$SCRIPT" "Rotate log files on remote hosts" \
    --name log-rotate --dir "$target" --approve 2>&1) || rc=$?
  expect_code 0 "$rc" "approve succeeds"
  assert_contains "$out" "Installed skill to:" "approve prints install path"
  [ -f "$target/log-rotate/SKILL.md" ] || fail "SKILL.md not created at target"
  pass "--approve copies generated skill to target directory"
}

test_approve_refuses_existing_dir() {
  local target out rc=0
  target="$TMP_ROOT/existing"
  mkdir -p "$target/old-skill"
  out=$("$SCRIPT" "Old skill" --name old-skill --dir "$target" --approve 2>&1) || rc=$?
  expect_code 1 "$rc" "approve-existing exits 1"
  assert_contains "$out" "target directory already exists" "refuses to clobber"
  pass "--approve refuses when target directory already exists"
}

test_tests_flag_creates_stub() {
  local target out rc=0
  target="$TMP_ROOT/with-tests"
  mkdir -p "$target"
  out=$("$SCRIPT" "Parse CSV files" --name csv-parser --dir "$target" --approve --tests 2>&1) || rc=$?
  expect_code 0 "$rc" "approve with tests succeeds"
  [ -d "$target/csv-parser/tests" ] || fail "tests/ directory not created"
  [ -f "$target/csv-parser/tests/test-csv-parser.sh" ] || fail "test stub not created"
  [ -x "$target/csv-parser/tests/test-csv-parser.sh" ] || fail "test stub not executable"
  pass "--tests creates executable test stub"
}

test_generated_skill_has_required_sections() {
  local target skill_md
  target="$TMP_ROOT/section-check"
  mkdir -p "$target"
  "$SCRIPT" "Analyze network latency" \
    --name net-latency --dir "$target" --approve >/dev/null 2>&1
  skill_md="$target/net-latency/SKILL.md"
  [ -f "$skill_md" ] || fail "SKILL.md missing"
  # Check frontmatter
  grep -q '^name: net-latency' "$skill_md" || fail "missing name in frontmatter"
  grep -q '^description:' "$skill_md" || fail "missing description in frontmatter"
  # Check required headings
  grep -q '## Triggers' "$skill_md" || fail "missing Triggers heading"
  grep -q '## Do NOT use for' "$skill_md" || fail "missing Do NOT use for heading"
  pass "generated SKILL.md has all required sections"
}

# Run all tests
test_usage_no_args
test_usage_help_flag
test_unknown_flag
test_generation_and_validation
test_auto_derived_name
test_approve_copies_skill
test_approve_refuses_existing_dir
test_tests_flag_creates_stub
test_generated_skill_has_required_sections

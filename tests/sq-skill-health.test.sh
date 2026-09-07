#!/usr/bin/env bash
# tests/sq-skill-health.test.sh - unit tests for bin/sq-skill-health.sh.
# Covers: full scan output (markdown table), single-skill report, JSON output,
# and empty skills directory handling.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/sq-skill-health.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# UNIT 1: Full scan outputs a markdown table with header and data rows.
# ---------------------------------------------------------------------------
unit_full_scan() {
  local out
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$ROOT" "$SCRIPT" 2>&1) || true

  # Must contain the header row
  if echo "$out" | grep -q '| Skill | Description |'; then
    pass "full-scan: header row present"
  else
    fail "full-scan: missing header row"
  fi

  # Must contain the separator row
  if echo "$out" | grep -q '|-------|-------------|'; then
    pass "full-scan: separator row present"
  else
    fail "full-scan: missing separator row"
  fi

  # Must contain at least one data row (afk is always present)
  if echo "$out" | grep -q '| afk |'; then
    pass "full-scan: afk skill row present"
  else
    fail "full-scan: afk skill row not found"
  fi

  # Must contain multiple skill rows (more than just afk)
  local row_count
  row_count=$(echo "$out" | grep -c '^| ' || true)
  if [ "$row_count" -gt 5 ]; then
    pass "full-scan: multiple skill rows present ($row_count)"
  else
    fail "full-scan: expected more than 5 rows, got $row_count"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 2: Single-skill report filters to just the named skill.
# ---------------------------------------------------------------------------
unit_single_skill() {
  local out
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$ROOT" "$SCRIPT" --skill afk 2>&1) || true

  # Must contain afk row
  if echo "$out" | grep -q '| afk |'; then
    pass "single-skill: afk row present"
  else
    fail "single-skill: afk row not found"
  fi

  # Must NOT contain other known skills
  if echo "$out" | grep -q '| debrief |'; then
    fail "single-skill: debrief row should not appear"
  else
    pass "single-skill: debrief row correctly excluded"
  fi

  if echo "$out" | grep -q '| drill |'; then
    fail "single-skill: drill row should not appear"
  else
    pass "single-skill: drill row correctly excluded"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 3: --json produces valid JSON array.
# ---------------------------------------------------------------------------
unit_json_output() {
  local out
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$ROOT" "$SCRIPT" --json 2>&1) || true

  # Validate complete JSON structure using python3
  if echo "$out" | python3 -m json.tool > /dev/null 2>&1; then
    pass "json: valid JSON structure"
  else
    fail "json: invalid JSON structure"
  fi

  # Must contain a valid JSON object for afk
  if echo "$out" | grep -q '"name":"afk"'; then
    pass "json: afk entry present"
  else
    fail "json: afk entry not found"
  fi

  # Count JSON objects between brackets
  local json_lines
  json_lines=$(echo "$out" | grep '^{' | wc -l || true)
  if [ "$json_lines" -gt 0 ]; then
    pass "json: $json_lines JSON objects found"
  else
    fail "json: no JSON objects found"
  fi

  # Single-skill JSON should have exactly one entry
  local single_json
  single_json=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$ROOT" "$SCRIPT" --json --skill afk 2>&1) || true
  local single_count
  single_count=$(echo "$single_json" | grep -c '^{' || true)
  if [ "$single_count" -eq 1 ]; then
    pass "json: single-skill produces exactly 1 entry"
  else
    fail "json: single-skill expected 1 entry, got $single_count"
  fi
}

# ---------------------------------------------------------------------------
# UNIT 4: Empty skills directory produces empty output.
# ---------------------------------------------------------------------------
unit_empty_skills() {
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sq-skill-health-empty.XXXXXX")
  mkdir -p "$tmpdir/.agents/skills"
  mkdir -p "$tmpdir/tests"

  # Create empty skills directory with no SKILL.md files
  local out
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$tmpdir" "$tmpdir/bin/sq-skill-health.sh" 2>&1) || true
  # Script won't exist in tmpdir, so we need to use the real script with overridden root
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$tmpdir" bash "$ROOT/bin/sq-skill-health.sh" 2>&1) || true

  # With no SKILL.md files, should say no skills found
  if echo "$out" | grep -q "No skill"; then
    pass "empty-skills: reports no skills"
  else
    fail "empty-skills: did not report no skills"
  fi

  # JSON mode should return empty array
  local json_out
  json_out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$tmpdir" bash "$ROOT/bin/sq-skill-health.sh" --json 2>&1) || true
  if echo "$json_out" | grep -q '^\[\]$'; then
    pass "empty-skills: JSON returns empty array"
  else
    # Check it's just brackets with no content
    if echo "$json_out" | grep -q '\[' && ! echo "$json_out" | grep -q '^{"name"'; then
      pass "empty-skills: JSON returns empty or near-empty array"
    else
      fail "empty-skills: JSON did not return empty array"
    fi
  fi

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# UNIT 5: has_tests detection works for known skills with tests.
# ---------------------------------------------------------------------------
unit_has_tests() {
  local out
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$ROOT" "$SCRIPT" --skill afk 2>&1) || true

  # afk has tests (sq-afk-launch.test.sh exists)
  if echo "$out" | grep -q '| yes |'; then
    pass "has-tests: afk reports tests=yes"
  else
    fail "has-tests: afk should report tests=yes"
  fi

  # diagnostic-reasoning has no tests
  out=$(SQUAD_STATE_OVERRIDE=/dev/null SQUAD_BASE="$ROOT" "$SCRIPT" --skill diagnostic-reasoning 2>&1) || true
  if echo "$out" | grep -q '| no |'; then
    pass "has-tests: diagnostic-reasoning reports tests=no"
  else
    fail "has-tests: diagnostic-reasoning should report tests=no"
  fi
}

# ---------------------------------------------------------------------------
# Run all units
# ---------------------------------------------------------------------------
printf 'Running sq-skill-health tests...\n'
unit_full_scan
unit_single_skill
unit_json_output
unit_empty_skills
unit_has_tests

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  printf 'FAILED: %d test(s)\n' "$FAILED"
  exit 1
else
  printf 'All tests passed.\n'
  exit 0
fi

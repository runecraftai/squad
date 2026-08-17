#!/usr/bin/env bash
# sq-board.test.sh - tests for the sq-board mission-planning board.
#
# Tests the data collection, filtering, and output formatting of sq-board.sh
# using a mock Squad state directory (no real Squad base required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD="$SCRIPT_DIR/../packages/sq-board/bin/sq-board.sh"
PASS=0
FAIL=0

# Create mock Squad base
MOCK_BASE=$(mktemp -d)
trap 'rm -rf "$MOCK_BASE"' EXIT

# Set up mock state directory
mkdir -p "$MOCK_BASE/state"
mkdir -p "$MOCK_BASE/data"

# Create mock backlog.md
cat > "$MOCK_BASE/data/backlog.md" <<'BACKLOG'
# Backlog

## In flight
- [ ] alpha-task - Alpha implementation task (repo: test-repo) (kind: strike) (since 2025-08-17)
- [ ] beta-recon - Beta investigation (repo: test-repo) (kind: recon) (since 2025-08-17)

## Held
- [ ] gamma-held - Gamma waiting for decision (repo: other-repo) (kind: commander) (hold: waiting for approval) (hold-kind: commander) (since 2025-08-16)

## Queued
- [ ] delta-queued - Delta ready to go (repo: test-repo) (kind: strike) (since 2025-08-15)

## Done
- [ ] epsilon-done - Epsilon completed (repo: test-repo) (kind: strike) (since 2025-08-14)
BACKLOG

# Create mock meta files
cat > "$MOCK_BASE/state/alpha-task.meta" <<'META'
window=test:alpha
endpoint_task_id=alpha-task
model=test-model/v1
effort=high
mode=drill
kind=strike
backend=tmux
META

cat > "$MOCK_BASE/state/beta-recon.meta" <<'META'
window=test:beta
endpoint_task_id=beta-recon
model=test-model/v2
effort=medium
mode=herdr
kind=recon
backend=herdr
META

# Create mock window-states
cat > "$MOCK_BASE/state/window-states" <<'WS'
test:alpha	alpha-task	working	working	implementing feature X
test:beta	beta-recon	idle	idle	external wait
WS

# Create mock status files
echo "working: implementing feature X" > "$MOCK_BASE/state/alpha-task.status"
echo "paused: waiting for upstream release" > "$MOCK_BASE/state/beta-recon.status"

# --- Test helpers ---
pass() {
  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ✗ %s\n' "$1"
  [ -n "${2:-}" ] && printf '    expected: %s\n    got:      %s\n' "$2" "$3"
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    pass "$desc"
  else
    fail "$desc" "to contain '$needle'" "(not found)"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    fail "$desc" "to NOT contain '$needle'" "(found)"
  else
    pass "$desc"
  fi
}

assert_json_field() {
  local desc="$1" item_id="$2" expected="$3" json="$4" field="$5"
  local actual
  actual=$(printf '%s' "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    if item['id'] == sys.argv[1]:
        print(item.get(sys.argv[2], ''))
        break
" "$item_id" "$field" 2>/dev/null || echo "")
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc" "'$expected'" "'$actual'"
  fi
}

# --- Tests ---
printf '\n=== sq-board tests ===\n\n'

# Test 1: Default output includes in-flight tasks
printf '%s\n' '-- Table mode --'
output=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" 2>&1)
assert_contains "shows alpha-task in output" "alpha-task" "$output"
assert_contains "shows beta-recon in output" "beta-recon" "$output"
assert_contains "shows IN FLIGHT section" "IN FLIGHT" "$output"
assert_contains "shows QUEUED section" "QUEUED" "$output"
assert_contains "shows HELD section" "HELD" "$output"
assert_not_contains "hides DONE by default" "epsilon-done" "$output"

# Test 2: Shows model and effort
assert_contains "shows model" "test-model" "$output"
assert_contains "shows effort" "high" "$output"

# Test 3: Shows delivery mode
assert_contains "shows drill mode" "[drill]" "$output"
assert_contains "shows herdr mode" "[herdr]" "$output"

# Test 4: Shows endpoint detail
assert_contains "shows endpoint detail" "implementing feature X" "$output"

# Test 5: --with-done includes done items
printf '\n-- With done --\n'
output_done=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --with-done 2>&1)
assert_contains "shows done items with --with-done" "epsilon-done" "$output_done"

# Test 6: --state filter
printf '\n-- State filter --\n'
output_flight=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --state in_flight 2>&1)
assert_contains "shows in_flight tasks" "alpha-task" "$output_flight"
assert_not_contains "hides queued tasks" "delta-queued" "$output_flight"
assert_not_contains "hides held tasks" "gamma-held" "$output_flight"

# Test 7: --kind filter
printf '\n-- Kind filter --\n'
output_strike=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --kind strike 2>&1)
assert_contains "shows strike tasks" "alpha-task" "$output_strike"
assert_not_contains "hides recon tasks" "beta-recon" "$output_strike"

# Test 8: Combined filter
printf '\n-- Combined filter --\n'
output_both=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --state in_flight --kind strike 2>&1)
assert_contains "shows matching task" "alpha-task" "$output_both"
assert_not_contains "hides non-matching kind" "beta-recon" "$output_both"

# Test 9: Compact mode
printf '\n-- Compact mode --\n'
output_compact=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --compact 2>&1)
assert_contains "compact shows task id" "alpha-task" "$output_compact"
assert_contains "compact shows kind" "strike" "$output_compact"

# Test 10: JSON mode
printf '\n-- JSON mode --\n'
output_json=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --json 2>&1)
# Validate it's valid JSON
if printf '%s' "$output_json" | python3 -c "import json, sys; json.load(sys.stdin)" 2>/dev/null; then
  pass "JSON output is valid JSON"
else
  fail "JSON output is valid JSON"
fi
assert_json_field "JSON alpha-task has correct state" "alpha-task" "in_flight" "$output_json" "state"
assert_json_field "JSON alpha-task has correct kind" "alpha-task" "strike" "$output_json" "kind"
assert_json_field "JSON alpha-task has model" "alpha-task" "test-model/v1" "$output_json" "model"
assert_json_field "JSON alpha-task has mode" "alpha-task" "drill" "$output_json" "mode"

# Test 12: No matches shows message
printf '\n-- No matches --\n'
output_empty=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" '--state' 'done' 2>&1)
assert_contains "shows no-match message" "No missions match" "$output_empty"

# Test 13: --help
printf '\n-- Help --\n'
output_help=$(SQUAD_BASE="$MOCK_BASE" "$BOARD" --help 2>&1 || true)
assert_contains "help shows usage" "usage: sq-board" "$output_help"

# --- Summary ---
printf '\n=== Results: %d passed, %d failed ===\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# Tests for bin/sq-dispatch-tune.sh - dispatch profile analysis.
#
# Verifies: metric extraction, recommendation generation, JSON output,
# empty data handling, profile filtering, and argument validation.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TUNE="$ROOT/bin/sq-dispatch-tune.sh"

# ── fixtures ──────────────────────────────────────────────────────────────

# Create a fake state directory with meta and status files.
# Usage: setup_fixtures <state_dir> <task_count>
setup_fixtures() {
  local state_dir="$1"
  local count="${2:-5}"
  mkdir -p "$state_dir"

  local i task_id harness model effort outcome

  for i in $(seq 1 "$count"); do
    task_id="test-task-$i"

    # Vary harness/model/effort across tasks.
    case $((i % 3)) in
      0) harness="claude"; model="sonnet"; effort="default" ;;
      1) harness="claude"; model="opus"; effort="xhigh" ;;
      2) harness="codex"; model="default"; effort="low" ;;
    esac

    # Vary outcomes: tasks 1-3 succeed, 4-5 fail.
    if [ "$i" -le 3 ]; then
      outcome="done"
    else
      outcome="failed"
    fi

    # Write meta file.
    cat > "$state_dir/$task_id.meta" <<METAEOF
window=tmux:$task_id
endpoint_task_id=$task_id
worktree=/tmp/worktree-$task_id
project=/tmp/project
harness=$harness
kind=strike
mode=drill
model=$model
effort=$effort
METAEOF

    # Write status file with the outcome.
    echo "$outcome: task completed" > "$state_dir/$task_id.status"
  done
}

# Create a fixture with a specific profile distribution for recommendation testing.
setup_recommendation_fixtures() {
  local state_dir="$1"
  mkdir -p "$state_dir"

  local i task_id

  # Profile A: 10 tasks, 10 success = 100% success rate (should recommend increase)
  for i in $(seq 1 10); do
    task_id="profile-a-$i"
    cat > "$state_dir/$task_id.meta" <<METAEOF
window=tmux:$task_id
endpoint_task_id=$task_id
harness=claude
model=sonnet
effort=default
METAEOF
    echo "done: completed" > "$state_dir/$task_id.status"
  done

  # Profile B: 10 tasks, 2 success = 20% success rate (should recommend reduce)
  for i in $(seq 1 10); do
    task_id="profile-b-$i"
    cat > "$state_dir/$task_id.meta" <<METAEOF
window=tmux:$task_id
endpoint_task_id=$task_id
harness=claude
model=opus
effort=xhigh
METAEOF
    if [ "$i" -le 2 ]; then
      echo "done: completed" > "$state_dir/$task_id.status"
    else
      echo "failed: error" > "$state_dir/$task_id.status"
    fi
  done

  # Profile C: 5 tasks, 5 failures = 100% failure rate (should recommend avoid)
  for i in $(seq 1 5); do
    task_id="profile-c-$i"
    cat > "$state_dir/$task_id.meta" <<METAEOF
window=tmux:$task_id
endpoint_task_id=$task_id
harness=codex
model=default
effort=low
METAEOF
    echo "failed: error" > "$state_dir/$task_id.status"
  done
}

# ── tests ─────────────────────────────────────────────────────────────────

echo "=== Empty Data Handling ==="

# Test 1: No state files at all.
TMP_ROOT=$(fm_test_tmproot dispatch-tune-empty)
EMPTY_STATE="$TMP_ROOT/empty-state"
mkdir -p "$EMPTY_STATE"

output=$(SQUAD_STATE_OVERRIDE="$EMPTY_STATE" "$TUNE" --json 2>&1)
if echo "$output" | grep -q '"tasks":0'; then
  pass "empty data returns tasks=0 in JSON"
else
  fail "empty data JSON: $output"
fi

# Test 2: Markdown output with no data.
output=$(SQUAD_STATE_OVERRIDE="$EMPTY_STATE" "$TUNE" 2>&1)
if echo "$output" | grep -q "No completed tasks found"; then
  pass "empty data returns helpful message in markdown"
else
  fail "empty data markdown: $output"
fi

# Test 3: Very large period catches existing tasks.
output=$(SQUAD_STATE_OVERRIDE="$EMPTY_STATE" "$TUNE" --period 36500 2>&1)
if echo "$output" | grep -q "No completed tasks found"; then
  pass "large period with no data still reports empty"
else
  fail "large period empty: $output"
fi

echo ""
echo "=== Argument Validation ==="

# Test 4: --period without value.
if output=$("$TUNE" --period 2>&1); then
  fail "--period without value should fail"
else
  pass "--period without value exits non-zero"
fi

# Test 5: --profile without value.
if output=$("$TUNE" --profile 2>&1); then
  fail "--profile without value should fail"
else
  pass "--profile without value exits non-zero"
fi

# Test 6: Unknown option.
if output=$("$TUNE" --bogus 2>&1); then
  fail "unknown option should fail"
else
  pass "unknown option exits non-zero"
fi

# Test 7: --help exits cleanly.
if "$TUNE" --help >/dev/null 2>&1; then
  pass "--help exits cleanly"
else
  fail "--help should succeed"
fi

# Test 8: --period with non-numeric value.
if output=$("$TUNE" --period abc 2>&1); then
  fail "--period with non-numeric should fail"
else
  pass "--period with non-numeric exits non-zero"
fi

echo ""
echo "=== Metric Extraction ==="

# Test 9: Tasks with meta files are correctly parsed.
FIXTURE_STATE="$TMP_ROOT/metric-state"
setup_fixtures "$FIXTURE_STATE" 5

output=$(SQUAD_STATE_OVERRIDE="$FIXTURE_STATE" "$TUNE" --json 2>&1)

# Check that we got 5 tasks.
if echo "$output" | grep -q '"tasks":5'; then
  pass "correctly counts 5 tasks from fixtures"
else
  fail "task count wrong: $output"
fi

# Test 10: Profiles are correctly computed.
# We have 3 profiles: claude/sonnet/default, claude/opus/xhigh, codex/default/low
if echo "$output" | grep -q 'claude/sonnet/default'; then
  pass "claude/sonnet/default profile found"
else
  fail "claude/sonnet/default not found: $output"
fi

if echo "$output" | grep -q 'claude/opus/xhigh'; then
  pass "claude/opus/xhigh profile found"
else
  fail "claude/opus/xhigh not found: $output"
fi

if echo "$output" | grep -q 'codex/default/low'; then
  pass "codex/default/low profile found"
else
  fail "codex/default/low not found: $output"
fi

echo ""
echo "=== Recommendation Generation ==="

# Test 11: High success rate profile gets "increase" recommendation.
REC_STATE="$TMP_ROOT/rec-state"
setup_recommendation_fixtures "$REC_STATE"

output=$(SQUAD_STATE_OVERRIDE="$REC_STATE" "$TUNE" 2>&1)

if echo "$output" | grep -q 'Increase usage of claude/sonnet/default'; then
  pass "recommends increasing high-success profile"
else
  fail "missing increase recommendation: $output"
fi

# Test 12: Low success rate profile gets "reduce" recommendation.
if echo "$output" | grep -q 'Reduce usage of'; then
  pass "recommends reducing low-success profile"
else
  fail "missing reduce recommendation: $output"
fi

# Test 13: High failure count gets "avoid" recommendation.
if echo "$output" | grep -q 'Avoid codex/default/low'; then
  pass "recommends avoiding high-failure profile"
else
  fail "missing avoid recommendation: $output"
fi

echo ""
echo "=== JSON Output ==="

# Test 14: JSON output is valid structure.
output=$(SQUAD_STATE_OVERRIDE="$REC_STATE" "$TUNE" --json 2>&1)

if echo "$output" | grep -q '"period_days":30'; then
  pass "JSON contains period_days"
else
  fail "JSON missing period_days: $output"
fi

if echo "$output" | grep -q '"profiles":\['; then
  pass "JSON contains profiles array"
else
  fail "JSON missing profiles array: $output"
fi

if echo "$output" | grep -q '"recommendations":\['; then
  pass "JSON contains recommendations array"
else
  fail "JSON missing recommendations array: $output"
fi

# Test 15: JSON recommendations have correct actions.
if echo "$output" | grep -q '"action":"increase"'; then
  pass "JSON has increase recommendation"
else
  fail "JSON missing increase recommendation: $output"
fi

if echo "$output" | grep -q '"action":"reduce"'; then
  pass "JSON has reduce recommendation"
else
  fail "JSON missing reduce recommendation: $output"
fi

if echo "$output" | grep -q '"action":"avoid"'; then
  pass "JSON has avoid recommendation"
else
  fail "JSON missing avoid recommendation: $output"
fi

echo ""
echo "=== Markdown Output ==="

# Test 16: Markdown has table header.
output=$(SQUAD_STATE_OVERRIDE="$REC_STATE" "$TUNE" 2>&1)

if echo "$output" | grep -q '| Profile | Tasks | Success Rate | Avg Duration |'; then
  pass "markdown has table header"
else
  fail "markdown missing table header: $output"
fi

# Test 17: Markdown has section headers.
if echo "$output" | grep -q '## Per-Profile Metrics'; then
  pass "markdown has metrics section"
else
  fail "markdown missing metrics section: $output"
fi

if echo "$output" | grep -q '## Recommendations'; then
  pass "markdown has recommendations section"
else
  fail "markdown missing recommendations section: $output"
fi

echo ""
echo "=== Profile Filtering ==="

# Test 18: --profile filters to matching profiles.
FILTER_STATE="$TMP_ROOT/filter-state"
setup_fixtures "$FILTER_STATE" 5

output=$(SQUAD_STATE_OVERRIDE="$FILTER_STATE" "$TUNE" --json --profile "claude/sonnet" 2>&1)

if echo "$output" | grep -q '"tasks":1'; then
  pass "--profile filter returns correct subset"
else
  fail "--profile filter wrong count: $output"
fi

# Test 19: Filter with no matches returns empty.
output=$(SQUAD_STATE_OVERRIDE="$FILTER_STATE" "$TUNE" --json --profile "nonexistent" 2>&1)

if echo "$output" | grep -q '"tasks":0'; then
  pass "--profile with no matches returns tasks=0"
else
  fail "--profile no match: $output"
fi

echo ""
echo "=== Verbose Output ==="

# Test 20: --verbose includes task detail table.
output=$(SQUAD_STATE_OVERRIDE="$FIXTURE_STATE" "$TUNE" --verbose 2>&1)

if echo "$output" | grep -q '## Task Detail'; then
  pass "--verbose includes task detail section"
else
  fail "--verbose missing task detail: $output"
fi

echo ""
echo "=== Missing Metadata Handling ==="

# Test 21: Tasks without meta files get "unknown" profile.
NOMETA_STATE="$TMP_ROOT/nometa-state"
mkdir -p "$NOMETA_STATE"
echo "done: completed" > "$NOMETA_STATE/orphan-task.status"

output=$(SQUAD_STATE_OVERRIDE="$NOMETA_STATE" "$TUNE" --json 2>&1)

if echo "$output" | grep -q 'unknown/unknown/unknown'; then
  pass "tasks without meta get unknown profile"
else
  fail "missing meta handling: $output"
fi

echo ""
echo "=== Status Files Without Terminal State ==="

# Test 22: Tasks with only working: lines are skipped.
NOWORKING_STATE="$TMP_ROOT/noworking-state"
mkdir -p "$NOWORKING_STATE"
echo "working: still in progress" > "$NOWORKING_STATE/running-task.status"

output=$(SQUAD_STATE_OVERRIDE="$NOWORKING_STATE" "$TUNE" --json 2>&1)

if echo "$output" | grep -q '"tasks":0'; then
  pass "tasks without terminal state are skipped"
else
  fail "non-terminal task not skipped: $output"
fi

# ── cleanup ───────────────────────────────────────────────────────────────

rm -rf "$TMP_ROOT"

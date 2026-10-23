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
# Keep the base's private data/ out of every run unless a case names its own log directory.
export SQUAD_DATA_OVERRIDE="$TMP_ROOT/no-dispatch-log"
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

echo ""
echo "=== Dispatch Log (log-first) ==="

# A dispatch log row mirrors sq-dispatch-log.sh; ids are plain names, so no escaping is needed.
write_log() { # <data_dir> <id> <row>...
  local dir="$1/$2"
  mkdir -p "$dir"
  shift 2
  printf '%s\n' "$@" > "$dir/dispatch.jsonl"
}

LOG_DATA="$TMP_ROOT/log-data"
TORN_STATE="$TMP_ROOT/torn-state"
mkdir -p "$TORN_STATE"

# closed-a: recommended claude/sonnet/default, dispatched claude/opus/xhigh, done.
write_log "$LOG_DATA" closed-a \
  '{"timestamp":"2026-10-20T10:00:00+00:00","id":"closed-a","event":"decision","harness":"claude","model":"sonnet","effort":"default","profile":"closed-scope","quota_summary":{"status":"unknown"}}' \
  '{"timestamp":"2026-10-20T10:00:05+00:00","id":"closed-a","event":"spawn","harness":"claude","model":"opus","effort":"xhigh"}' \
  '{"timestamp":"2026-10-20T10:20:05+00:00","id":"closed-a","event":"outcome","source":"status-notify","result":"done"}' \
  '{"timestamp":"2026-10-20T10:30:05+00:00","id":"closed-a","event":"outcome","source":"teardown","result":"released"}'

# closed-b: recommended and dispatched claude/sonnet/default, landed on merge.
write_log "$LOG_DATA" closed-b \
  '{"timestamp":"2026-10-20T11:00:00+00:00","id":"closed-b","event":"decision","harness":"claude","model":"sonnet","effort":"default","profile":"closed-scope","quota_summary":{"status":"unknown"}}' \
  '{"timestamp":"2026-10-20T11:00:05+00:00","id":"closed-b","event":"spawn","harness":"claude","model":"sonnet","effort":"default"}' \
  '{"timestamp":"2026-10-20T11:40:05+00:00","id":"closed-b","event":"outcome","source":"pr-merge","result":"landed"}'

# closed-c: a reason-only decision (no lane), dispatched codex/gpt-5/high, failed.
write_log "$LOG_DATA" closed-c \
  '{"timestamp":"2026-10-20T12:00:00+00:00","id":"closed-c","event":"decision","harness":"codex","model":"gpt-5","effort":"high","reason":"SENTINEL_REASON_TEXT","quota_summary":{"status":"unknown"}}' \
  '{"timestamp":"2026-10-20T12:00:05+00:00","id":"closed-c","event":"spawn","harness":"codex","model":"gpt-5","effort":"high"}' \
  '{"timestamp":"2026-10-20T12:15:05+00:00","id":"closed-c","event":"outcome","source":"status-notify","result":"failed"}'

# Three torn-down tasks: only their logs survive, so no status or meta files exist.
output=$(SQUAD_STATE_OVERRIDE="$TORN_STATE" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --json 2>&1)

if echo "$output" | grep -q '"tasks":3'; then
  pass "torn-down tasks with only a log are counted"
else
  fail "torn-down task count wrong: $output"
fi

if echo "$output" | grep -q '"profile":"claude/opus/xhigh"' &&
   echo "$output" | grep -q '"profile":"claude/sonnet/default"' &&
   echo "$output" | grep -q '"profile":"codex/gpt-5/high"'; then
  pass "log-only tasks report their real dispatched profiles"
else
  fail "log-only profiles missing: $output"
fi

if echo "$output" | grep -q 'unknown/unknown/unknown'; then
  fail "a task with a log read as unknown/unknown/unknown: $output"
else
  pass "a task whose log exists never reads as unknown/unknown/unknown"
fi

if echo "$output" | grep -q 'SENTINEL_REASON_TEXT'; then
  fail "decision reason text leaked into the report"
else
  pass "decision reason text is never printed"
fi

# One unreadable log must not blank the others: the readable task keeps its real profile.
UNREADABLE_DATA="$TMP_ROOT/unreadable-data"
write_log "$UNREADABLE_DATA" closed-a \
  '{"timestamp":"2026-10-20T10:00:00+00:00","id":"closed-a","event":"decision","harness":"claude","model":"sonnet","effort":"default","profile":"closed-scope","quota_summary":{"status":"unknown"}}' \
  '{"timestamp":"2026-10-20T10:00:05+00:00","id":"closed-a","event":"spawn","harness":"claude","model":"opus","effort":"xhigh"}' \
  '{"timestamp":"2026-10-20T10:20:05+00:00","id":"closed-a","event":"outcome","source":"status-notify","result":"done"}'
UNREADABLE_STATE="$TMP_ROOT/unreadable-state"
mkdir -p "$UNREADABLE_STATE"
cat > "$UNREADABLE_STATE/closed-b.meta" <<'METAEOF'
harness=pi
model=gpt-5
effort=high
METAEOF
echo "done: PR https://example.invalid/pull/2 checks green" > "$UNREADABLE_STATE/closed-b.status"
if [ "$(id -u)" -eq 0 ]; then
  echo "skip: unreadable-log case needs a non-root user (mode 000 is readable by root)"
else
  mkdir -p "$UNREADABLE_DATA/closed-b"
  printf '%s\n' '{"timestamp":"2026-10-20T11:00:00+00:00","id":"closed-b","event":"decision","harness":"pi","model":"gpt-5","effort":"high","profile":"pi/gpt-5/high"}' > "$UNREADABLE_DATA/closed-b/dispatch.jsonl"
  chmod 000 "$UNREADABLE_DATA/closed-b/dispatch.jsonl"
  output=$(SQUAD_STATE_OVERRIDE="$UNREADABLE_STATE" SQUAD_DATA_OVERRIDE="$UNREADABLE_DATA" "$TUNE" --json 2>&1)
  if echo "$output" | grep -q '"profile":"claude/opus/xhigh"' &&
     echo "$output" | grep -q '"profile":"pi/gpt-5/high"'; then
    pass "an unreadable dispatch log does not hide the other tasks or the meta fallback"
  else
    fail "unreadable log dropped a task: $output"
  fi
fi

# Log-first precedence: a meta file that disagrees must not override the spawn row.
mkdir -p "$TMP_ROOT/log-meta-state"
cat > "$TMP_ROOT/log-meta-state/closed-a.meta" <<'METAEOF'
harness=codex
model=wrong
effort=none
METAEOF
echo "done: PR https://example.invalid/pull/1 checks green" > "$TMP_ROOT/log-meta-state/closed-a.status"
output=$(SQUAD_STATE_OVERRIDE="$TMP_ROOT/log-meta-state" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --json 2>&1)
if echo "$output" | grep -q '"profile":"codex/wrong/none"'; then
  fail "meta overrode the log's spawn row: $output"
else
  pass "log-first: a disagreeing meta file does not override the spawn row"
fi

echo ""
echo "=== Dispatch Log Fallback (meta) ==="

# A task with no log falls back to its meta file for the profile.
META_STATE="$TMP_ROOT/meta-state"
mkdir -p "$META_STATE"
cat > "$META_STATE/meta-only.meta" <<'METAEOF'
harness=pi
model=gpt-5
effort=high
METAEOF
echo "done: finished" > "$META_STATE/meta-only.status"
output=$(SQUAD_STATE_OVERRIDE="$META_STATE" SQUAD_DATA_OVERRIDE="$TMP_ROOT/no-dispatch-log" "$TUNE" --json 2>&1)
if echo "$output" | grep -q '"profile":"pi/gpt-5/high"'; then
  pass "task without a log falls back to its meta profile"
else
  fail "meta fallback profile missing: $output"
fi

echo ""
echo "=== By Lane ==="

output=$(SQUAD_STATE_OVERRIDE="$TORN_STATE" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --json --by-lane 2>&1)
# closed-scope: two dispatches, both successful, one off its recommended model.
if echo "$output" | grep -q '"lane":"closed-scope","dispatches":2,"success_rate":100.0,"off_recommendation":1'; then
  pass "--by-lane counts dispatches and off-recommendation per lane"
else
  fail "--by-lane lane summary wrong: $output"
fi

if echo "$output" | grep -q '"lane":"(no-profile)","dispatches":1,"success_rate":0.0,"off_recommendation":0'; then
  pass "--by-lane groups reason-only decisions under (no-profile)"
else
  fail "--by-lane no-profile lane wrong: $output"
fi

if echo "$output" | grep -q '"chosen":\[{"profile":"claude/opus/xhigh","dispatches":1},{"profile":"claude/sonnet/default","dispatches":1}\]'; then
  pass "--by-lane lists the models chosen within a lane"
else
  fail "--by-lane chosen models wrong: $output"
fi

output=$(SQUAD_STATE_OVERRIDE="$TORN_STATE" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --by-lane 2>&1)
if echo "$output" | grep -q '^## Lanes' && echo "$output" | grep -q '| closed-scope | 2 | claude/opus/xhigh x1, claude/sonnet/default x1 | 1 | 100.0% |'; then
  pass "--by-lane markdown renders the lane table"
else
  fail "--by-lane markdown wrong: $output"
fi

if echo "$output" | grep -q 'SENTINEL_REASON_TEXT'; then
  fail "--by-lane leaked the decision reason"
else
  pass "--by-lane never prints decision reason text"
fi

echo ""
echo "=== Fallback Rate ==="

# Live state: closed-a (no quota wording), closed-c (provider outage), meta-only (plain failure),
# closed-b has no status file (torn-down-like, so unknown). A "working:" mention of quota must not count.
FALLBACK_STATE="$TMP_ROOT/fallback-state"
mkdir -p "$FALLBACK_STATE"
cp "$TMP_ROOT/log-meta-state/closed-a.status" "$FALLBACK_STATE/closed-a.status"
cat > "$FALLBACK_STATE/closed-c.status" <<'STATUSEOF'
paused: provider outage, waiting on upstream
failed: provider outage
STATUSEOF
printf 'working: adding quota tests\ndone: PR https://example.invalid/pull/2 checks green\n' > "$FALLBACK_STATE/meta-only.status"
cp "$META_STATE/meta-only.meta" "$FALLBACK_STATE/meta-only.meta"

output=$(SQUAD_STATE_OVERRIDE="$FALLBACK_STATE" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --json --fallback-rate 2>&1)
# Overall: 3 observed (1 hit), 1 unknown, so 33.3%.
if echo "$output" | grep -q '"fallback":{"hits":1,"observed":3,"unknown":1,"rate":33.3}'; then
  pass "--fallback-rate counts provider or quota hits against observed tasks"
else
  fail "--fallback-rate overall wrong: $output"
fi

# A "working:" line that merely mentions quota is not a stopped run, so the meta-only task is a miss.
output=$(SQUAD_STATE_OVERRIDE="$FALLBACK_STATE" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --json --by-lane --fallback-rate 2>&1)
if echo "$output" | grep -q '"lane":"(no-profile)".*"fallback":{"hits":1,"observed":2,"unknown":0,"rate":50.0}'; then
  pass "--by-lane --fallback-rate reports fallback per lane"
else
  fail "--by-lane --fallback-rate lane wrong: $output"
fi

output=$(SQUAD_STATE_OVERRIDE="$FALLBACK_STATE" SQUAD_DATA_OVERRIDE="$LOG_DATA" "$TUNE" --fallback-rate 2>&1)
if echo "$output" | grep -q '^## Fallback Rate' && echo "$output" | grep -q -- '- \*\*Fallback rate:\*\* 33.3% of observed tasks'; then
  pass "--fallback-rate markdown renders the fallback section"
else
  fail "--fallback-rate markdown wrong: $output"
fi

if echo "$output" | grep -q 'provider outage'; then
  fail "--fallback-rate printed status text"
else
  pass "--fallback-rate never prints status text"
fi

# Empty JSON keeps the requested sections present, so machine consumers see a stable shape.
output=$(SQUAD_STATE_OVERRIDE="$EMPTY_STATE" SQUAD_DATA_OVERRIDE="$TMP_ROOT/no-dispatch-log" "$TUNE" --json --by-lane --fallback-rate 2>&1)
if echo "$output" | grep -q '"tasks":0,"lanes":\[\],"fallback":{"hits":0,"observed":0,"unknown":0,"rate":null}'; then
  pass "empty --json keeps the lane and fallback sections"
else
  fail "empty --json with flags wrong: $output"
fi

echo ""
echo "=== Released, Chosen Profile, Failure Class, Credential Guard ==="

LOG_WRITER="$ROOT/bin/sq-dispatch-log.sh"
WRITE_STATE="$TMP_ROOT/writer-state"
mkdir -p "$WRITE_STATE"

# A torn-down task (released only, no done or failed row) still counts toward its lane.
write_log "$TMP_ROOT/released-data" rel-a \
  '{"timestamp":"2026-10-20T10:00:00+00:00","id":"rel-a","event":"decision","harness":"claude","model":"sonnet","effort":"default","profile":"rel-lane","quota_summary":{"status":"unknown"}}' \
  '{"timestamp":"2026-10-20T10:00:05+00:00","id":"rel-a","event":"spawn","harness":"claude","model":"sonnet","effort":"default"}' \
  '{"timestamp":"2026-10-20T10:30:00+00:00","id":"rel-a","event":"outcome","source":"teardown","result":"released"}'
output=$(SQUAD_STATE_OVERRIDE="$WRITE_STATE" SQUAD_DATA_OVERRIDE="$TMP_ROOT/released-data" "$TUNE" --json --by-lane --fallback-rate 2>&1)
if echo "$output" | grep -q '"tasks":1' &&
   echo "$output" | grep -q '"lane":"rel-lane","dispatches":1,"success_rate":null,"off_recommendation":0' &&
   echo "$output" | grep -q '"fallback":{"hits":0,"observed":0,"unknown":1,"rate":null}'; then
  pass "a released-only task counts toward its lane but is never a fallback"
else
  fail "released-only task mis-counted: $output"
fi

# With no spawn row, the chosen profile comes from state/<id>.meta, not the recommendation.
mkdir -p "$TMP_ROOT/chosen-state"
cat > "$TMP_ROOT/chosen-state/dec-a.meta" <<'METAEOF'
harness=pi
model=gpt-5
effort=high
METAEOF
echo "done: finished" > "$TMP_ROOT/chosen-state/dec-a.status"
write_log "$TMP_ROOT/chosen-data" dec-a \
  '{"timestamp":"2026-10-20T10:00:00+00:00","id":"dec-a","event":"decision","harness":"claude","model":"sonnet","effort":"default","profile":"dec-lane","quota_summary":{"status":"unknown"}}' \
  '{"timestamp":"2026-10-20T10:20:00+00:00","id":"dec-a","event":"outcome","source":"status-notify","result":"done"}'
output=$(SQUAD_STATE_OVERRIDE="$TMP_ROOT/chosen-state" SQUAD_DATA_OVERRIDE="$TMP_ROOT/chosen-data" "$TUNE" --json --by-lane 2>&1)
if echo "$output" | grep -q '"lane":"dec-lane","dispatches":1,"success_rate":100.0,"off_recommendation":1,"chosen":\[{"profile":"pi/gpt-5/high","dispatches":1}\]'; then
  pass "a decision without a spawn row takes its chosen profile from meta"
else
  fail "decision-only chosen profile wrong: $output"
fi

# The writer records a failure class from the status line, so the fallback survives status removal.
WRITE_DATA="$TMP_ROOT/writer-data"
echo "failed: provider overloaded, retrying later" > "$WRITE_STATE/prov-a.status"
SQUAD_STATE_OVERRIDE="$WRITE_STATE" SQUAD_DATA_OVERRIDE="$WRITE_DATA" "$LOG_WRITER" prov-a outcome --source status-notify --result failed
rm -f "$WRITE_STATE/prov-a.status"
output=$(SQUAD_STATE_OVERRIDE="$WRITE_STATE" SQUAD_DATA_OVERRIDE="$WRITE_DATA" "$TUNE" --json --fallback-rate 2>&1)
if echo "$output" | grep -q '"fallback":{"hits":1,"observed":1,"unknown":0,"rate":100.0}' &&
   ! grep -q "retrying later" "$WRITE_DATA/prov-a/dispatch.jsonl" 2>/dev/null; then
  pass "a provider failure class recorded at write time survives status removal, without status text"
else
  fail "writer failure class not used: $output"
fi

# A failure line with no keyword match is recorded as other, a miss rather than unknown.
echo "failed: unexplained crash" > "$WRITE_STATE/other-a.status"
OTHER_DATA="$TMP_ROOT/other-data"
SQUAD_STATE_OVERRIDE="$WRITE_STATE" SQUAD_DATA_OVERRIDE="$OTHER_DATA" "$LOG_WRITER" other-a outcome --source status-notify --result failed
rm -f "$WRITE_STATE/other-a.status"
output=$(SQUAD_STATE_OVERRIDE="$WRITE_STATE" SQUAD_DATA_OVERRIDE="$OTHER_DATA" "$TUNE" --json --fallback-rate 2>&1)
if echo "$output" | grep -q '"fallback":{"hits":0,"observed":1,"unknown":0,"rate":0.0}'; then
  pass "a failure line without a keyword is recorded as other, not unknown"
else
  fail "other failure class not a miss: $output"
fi

# A credential-shaped model is refused by the writer and never stored.
SECRET_DATA="$TMP_ROOT/secret-data"
SQUAD_STATE_OVERRIDE="$WRITE_STATE" SQUAD_DATA_OVERRIDE="$SECRET_DATA" "$LOG_WRITER" sec-a spawn \
  --harness claude --model sk-live-abcdefgh1234 --effort default >/dev/null 2>&1
if [ ! -e "$SECRET_DATA/sec-a/dispatch.jsonl" ]; then
  pass "a credential-shaped model is refused by the dispatch log writer"
else
  fail "credential-shaped model was stored"
fi

# A credential-shaped harness in meta prints as redacted, never verbatim.
mkdir -p "$TMP_ROOT/redact-state"
cat > "$TMP_ROOT/redact-state/redact-a.meta" <<'METAEOF'
harness=ghp_abcdefghijklmnop
model=gpt-5
effort=high
METAEOF
echo "done: finished" > "$TMP_ROOT/redact-state/redact-a.status"
output=$(SQUAD_STATE_OVERRIDE="$TMP_ROOT/redact-state" SQUAD_DATA_OVERRIDE="$TMP_ROOT/no-dispatch-log" "$TUNE" --json 2>&1)
if echo "$output" | grep -q 'ghp_abcdef'; then
  fail "credential-shaped harness printed: $output"
elif echo "$output" | grep -q '"profile":"redacted/gpt-5/high"'; then
  pass "a credential-shaped harness prints as redacted"
else
  fail "redacted profile missing: $output"
fi

# ── cleanup ───────────────────────────────────────────────────────────────

rm -rf "$TMP_ROOT"

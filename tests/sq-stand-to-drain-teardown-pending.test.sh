#!/usr/bin/env bash
# tests/sq-stand-to-drain-teardown-pending.test.sh - behavior tests for the
# TEARDOWN PENDING section bin/sq-stand-to-drain.sh prints on every drain
# (including the empty-queue fast path) when a task reported itself done: or
# failed: but bin/sq-teardown.sh has not run, so its state/<id>.meta is still
# live. Pure reminder wiring: it must never auto-run teardown and must stay
# silent when nothing matches. These tests exercise the real drain script over
# crafted state dirs and assert on its printed output, not on implementation
# source bytes.
set -u

# shellcheck source=tests/stand-to-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/stand-to-helpers.sh"

DRAIN="$ROOT/bin/sq-stand-to-drain.sh"

TMP_ROOT=$(fm_test_tmproot sq-stand-to-drain-teardown-pending-tests)

test_done_task_surfaces_teardown_pending() {
  local dir state out
  dir=$(make_case done-task)
  state="$dir/state"
  out="$dir/drain.out"
  # A live meta (teardown never ran) whose latest status line is done:.
  printf 'worktree=/tmp/x\nkind=strike\n' > "$state/task1.meta"
  printf 'working: on it\n' > "$state/task1.status"
  printf 'done: shipped clean\n' >> "$state/task1.status"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a finished task"

  grep -F 'TEARDOWN PENDING' "$out" >/dev/null || fail "a finished task produced no TEARDOWN PENDING section"
  grep -F 'task1' "$out" | grep -F 'done: shipped clean' >/dev/null \
    || fail "the finished task was not named with its done status: $(cat "$out")"
  pass "a task that finished but was never torn down surfaces a teardown reminder"
}

test_failed_task_surfaces_teardown_pending() {
  local dir state out
  dir=$(make_case failed-task)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'kind=strike\n' > "$state/task2.meta"
  printf 'failed: build broke\n' > "$state/task2.status"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a failed task"

  grep -F 'TEARDOWN PENDING' "$out" >/dev/null || fail "a failed task produced no TEARDOWN PENDING section"
  grep -F 'task2' "$out" | grep -F 'failed: build broke' >/dev/null \
    || fail "the failed task was not named with its failed status: $(cat "$out")"
  pass "a failed task that was never torn down also surfaces"
}

test_silent_when_nothing_matches() {
  local dir state out
  dir=$(make_case nothing-matches)
  state="$dir/state"
  out="$dir/drain.out"
  # Still working: meta exists but the latest status line is not done/failed.
  printf 'kind=strike\n' > "$state/task3.meta"
  printf 'working: on it\n' > "$state/task3.status"
  # Already torn down: done status but no meta (teardown removed it).
  printf 'done: shipped clean\n' > "$state/task4.status"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with nothing to report"

  if grep -F 'TEARDOWN PENDING' "$out" >/dev/null; then
    fail "a working task or a torn-down task printed a TEARDOWN PENDING section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the no-match case was not silent: $(cat "$out")"
  pass "no teardown pending across the unit prints nothing"
}

test_kind_xo_is_excluded() {
  local dir state out
  dir=$(make_case xo-excluded)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'kind=xo\nwindow=default:w1:p1\nworktree=/some/xo\n' > "$state/task5.meta"
  printf 'done: sharded work complete\n' > "$state/task5.status"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an XO task"

  if grep -F 'TEARDOWN PENDING' "$out" >/dev/null; then
    fail "a kind=xo task printed a TEARDOWN PENDING section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the xo-excluded case was not silent: $(cat "$out")"
  pass "kind=xo tasks are never flagged for the teardown reminder"
}

test_reminder_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake queued at all, but a finished task still has a live meta.
  printf 'kind=strike\n' > "$state/task6.meta"
  printf 'done: shipped clean\n' > "$state/task6.status"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'TEARDOWN PENDING' "$out" >/dev/null || fail "the empty-queue fast path did not surface the reminder"
  grep -F 'task6' "$out" | grep -F 'done: shipped clean' >/dev/null \
    || fail "the finished task was not named on the empty-queue fast path: $(cat "$out")"
  pass "the teardown reminder surfaces even when the stand-to queue itself is empty"
}

test_done_task_surfaces_teardown_pending
test_failed_task_surfaces_teardown_pending
test_silent_when_nothing_matches
test_kind_xo_is_excluded
test_reminder_surfaces_on_the_empty_queue_fast_path

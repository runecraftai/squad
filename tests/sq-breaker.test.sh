#!/usr/bin/env bash
# Behavior tests for bin/sq-breaker-lib.sh and bin/sq-breaker.sh.
#
# Verifies the circuit-breaker ladder policy:
#   (a) healthy → steering on repeated tool calls exceeding limit
#   (b) healthy → steering on error storm exceeding limit
#   (c) healthy → steering on no-progress beats exceeding limit
#   (d) escalation ladder: healthy → steering → constrained → stopped
#   (e) de-escalation: one level per healthy evaluation (recovery)
#   (f) hardStop=0 caps at constrained; hardStop=1 allows stopped
#   (g) action fires only on escalation, not on recovery
#   (h) CLI evaluate/status/reset commands work correctly
#   (i) shellcheck-clean
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BREAKER_LIB="$ROOT/bin/sq-breaker-lib.sh"
BREAKER_CLI="$ROOT/bin/sq-breaker.sh"
TMP_ROOT=$(fm_test_tmproot sq-breaker)

# Source the library for direct function tests
# shellcheck disable=SC1090,SC2034 # test source; env vars used by sourced library
. "$BREAKER_LIB"

# ── (a) repeated tool calls trip ───────────────────────────────────────────

test_repeated_tool_trip() {
  local result verdict action reason
  # Below limit: no trip
  result=$(sq_breaker_evaluate "healthy" "5" "read" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "repeat below limit should stay healthy, got: $verdict"
  pass "repeated tool calls below limit stay healthy"

  # At limit: trip to steering
  result=$(sq_breaker_evaluate "healthy" "8" "read" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  action=$(echo "$result" | cut -d'|' -f2)
  reason=$(echo "$result" | cut -d'|' -f3)
  [ "$verdict" = "steering" ] || fail "repeat at limit should steer, got: $verdict"
  [ "$action" = "steer" ] || fail "repeat trip should fire steer action, got: $action"
  assert_contains "$reason" "looping" "reason mentions looping"
  pass "repeated tool calls at limit trip to steering"

  # Over limit: still steering (one level per tick)
  result=$(sq_breaker_evaluate "steering" "10" "read" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "constrained" ] || fail "repeat over limit from steering should constrain, got: $verdict"
  pass "repeated tool calls over limit escalate from steering to constrained"
}

test_repeated_tool_trip

# ── (b) error storm trips ─────────────────────────────────────────────────

test_error_storm_trip() {
  local result verdict
  # Below limit: no trip
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "3" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "error below limit should stay healthy, got: $verdict"
  pass "error storm below limit stays healthy"

  # At limit: trip
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "5" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "steering" ] || fail "error at limit should steer, got: $verdict"
  local reason
  reason=$(echo "$result" | cut -d'|' -f3)
  assert_contains "$reason" "error storm" "reason mentions error storm"
  pass "error storm at limit trips to steering"
}

test_error_storm_trip

# ── (b2) parked states do NOT trip error counter ──────────────────────────

test_parked_states_not_errors() {
  local state_dir="$TMP_ROOT/parked-state"
  mkdir -p "$state_dir"
  local status_file="$state_dir/parked-task.status"

  # A sequence of blocked/paused/needs-decision lines should NOT accumulate
  # an error count — they are legitimate waits, not error storms.
  cat > "$status_file" <<'EOF'
working: starting task
blocked: waiting on commander decision
blocked: still waiting
paused: external dependency delayed
needs-decision: which approach to take
blocked: rate limit reset pending
EOF
  local output
  # Reset breaker to healthy first
  SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" reset parked-task >/dev/null
  output=$(SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" evaluate parked-task)
  # Should remain healthy — parked states are not error signals
  local verdict
  verdict=$(echo "$output" | cut -d' ' -f1)
  [ "$verdict" = "healthy" ] || fail "parked states should not trip breaker, got: $verdict"
  pass "blocked/paused/needs-decision do not trip the breaker"

  # Mixed: error lines followed by a parked state should reset the counter.
  cat > "$status_file" <<'EOF'
working: doing work
error: api call failed
error: retry failed
blocked: waiting on external dep
error: another error after park
EOF
  SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" reset parked-task >/dev/null
  output=$(SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" evaluate parked-task)
  verdict=$(echo "$output" | cut -d' ' -f1)
  # Only 1 error after the blocked reset, below threshold → healthy
  [ "$verdict" = "healthy" ] || fail "parked state should reset error counter, got: $verdict"
  pass "blocked line resets error counter between error bursts"
}

test_parked_states_not_errors

# ── (b3) parked states count as progress ─────────────────────────────────

test_parked_states_are_progress() {
  local state_dir="$TMP_ROOT/parked-progress-state"
  mkdir -p "$state_dir"
  local status_file="$state_dir/parked-prog.status"

  # blocked: should count as progress (legitimate wait)
  echo "blocked: waiting on commander" > "$status_file"
  SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" reset parked-prog >/dev/null
  local output verdict
  output=$(SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" evaluate parked-prog)
  verdict=$(echo "$output" | cut -d' ' -f1)
  [ "$verdict" = "healthy" ] || fail "blocked should count as progress (healthy), got: $verdict"
  pass "blocked status counts as progress"

  # paused: should count as progress
  echo "paused: external dependency" > "$status_file"
  SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" reset parked-prog >/dev/null
  output=$(SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" evaluate parked-prog)
  verdict=$(echo "$output" | cut -d' ' -f1)
  [ "$verdict" = "healthy" ] || fail "paused should count as progress (healthy), got: $verdict"
  pass "paused status counts as progress"

  # needs-decision: should count as progress
  echo "needs-decision: which approach" > "$status_file"
  SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" reset parked-prog >/dev/null
  output=$(SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" evaluate parked-prog)
  verdict=$(echo "$output" | cut -d' ' -f1)
  [ "$verdict" = "healthy" ] || fail "needs-decision should count as progress (healthy), got: $verdict"
  pass "needs-decision status counts as progress"
}

test_parked_states_are_progress

# ── (c) no-progress streak trips ──────────────────────────────────────────

test_no_progress_trip() {
  local result verdict
  # Below limit with progress: no trip
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "0" "2" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "no-progress below limit with progress should stay healthy, got: $verdict"
  pass "no-progress below limit with progress stays healthy"

  # Below limit without progress: no trip yet
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "0" "2" "0")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "no-progress below limit without progress should stay healthy, got: $verdict"
  pass "no-progress below limit without progress stays healthy"

  # At limit without progress: trip
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "0" "3" "0")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "steering" ] || fail "no-progress at limit without progress should steer, got: $verdict"
  local reason
  reason=$(echo "$result" | cut -d'|' -f3)
  assert_contains "$reason" "no-progress" "reason mentions no-progress"
  pass "no-progress at limit without progress trips to steering"

  # At limit WITH progress: no trip (progress resets the streak)
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "0" "3" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "no-progress at limit with progress should stay healthy, got: $verdict"
  pass "no-progress at limit with progress stays healthy"
}

test_no_progress_trip

# ── (d) escalation ladder ─────────────────────────────────────────────────

test_escalation_ladder() {
  # healthy → steering → constrained (default hardStop=0)
  local result v1 v2 v3

  result=$(sq_breaker_evaluate "healthy" "8" "read" "0" "0" "1")
  v1=$(echo "$result" | cut -d'|' -f1)
  [ "$v1" = "steering" ] || fail "ladder step 1: healthy→steering, got: $v1"

  result=$(sq_breaker_evaluate "steering" "8" "read" "0" "0" "1")
  v2=$(echo "$result" | cut -d'|' -f1)
  [ "$v2" = "constrained" ] || fail "ladder step 2: steering→constrained, got: $v2"

  # With hardStop=0, can't go past constrained
  SQ_BREAKER_HARD_STOP=0
  result=$(sq_breaker_evaluate "constrained" "8" "read" "0" "0" "1")
  v3=$(echo "$result" | cut -d'|' -f1)
  [ "$v3" = "constrained" ] || fail "ladder step 3: constrained stays constrained with hardStop=0, got: $v3"
  SQ_BREAKER_HARD_STOP=0

  pass "escalation ladder: healthy → steering → constrained (hardStop=0)"
}

test_escalation_ladder

# ── (e) de-escalation / recovery ──────────────────────────────────────────

test_recovery() {
  local result verdict action reason

  # From constrained, one healthy eval → steering
  result=$(sq_breaker_evaluate "constrained" "0" "unknown" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  action=$(echo "$result" | cut -d'|' -f2)
  [ "$verdict" = "steering" ] || fail "recovery step 1: constrained→steering, got: $verdict"
  [ "$action" = "none" ] || fail "recovery should not fire action, got: $action"
  reason=$(echo "$result" | cut -d'|' -f3)
  assert_contains "$reason" "recovering" "reason mentions recovery"
  pass "recovery from constrained to steering"

  # From steering, one healthy eval → healthy
  result=$(sq_breaker_evaluate "steering" "0" "unknown" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "recovery step 2: steering→healthy, got: $verdict"
  pass "recovery from steering to healthy"

  # Already healthy, still healthy
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "healthy" ] || fail "recovery: already healthy stays healthy, got: $verdict"
  pass "recovery: already healthy stays healthy"
}

test_recovery

# ── (f) hardStop behavior ─────────────────────────────────────────────────

test_hard_stop() {
  local result verdict

  # hardStop=1: constrained → stopped
  SQ_BREAKER_HARD_STOP=1
  result=$(sq_breaker_evaluate "constrained" "8" "read" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "stopped" ] || fail "hardStop=1 should allow stopped, got: $verdict"
  pass "hardStop=1 allows stopped"

  # hardStop=0: constrained stays constrained
  # shellcheck disable=SC2034 # used by sourced sq_breaker_evaluate
  SQ_BREAKER_HARD_STOP=0
  result=$(sq_breaker_evaluate "constrained" "8" "read" "0" "0" "1")
  verdict=$(echo "$result" | cut -d'|' -f1)
  [ "$verdict" = "constrained" ] || fail "hardStop=0 should cap at constrained, got: $verdict"
  pass "hardStop=0 caps at constrained"
}

test_hard_stop

# ── (g) action only on escalation ─────────────────────────────────────────

test_action_only_on_escalation() {
  local result action

  # Escalation: action fires
  result=$(sq_breaker_evaluate "healthy" "8" "read" "0" "0" "1")
  action=$(echo "$result" | cut -d'|' -f2)
  [ "$action" = "steer" ] || fail "escalation should fire action, got: $action"
  pass "escalation fires action"

  # Recovery: no action
  result=$(sq_breaker_evaluate "constrained" "0" "unknown" "0" "0" "1")
  action=$(echo "$result" | cut -d'|' -f2)
  [ "$action" = "none" ] || fail "recovery should not fire action, got: $action"
  pass "recovery does not fire action"

  # No change: no action
  result=$(sq_breaker_evaluate "healthy" "0" "unknown" "0" "0" "1")
  action=$(echo "$result" | cut -d'|' -f2)
  [ "$action" = "none" ] || fail "no change should not fire action, got: $action"
  pass "no change does not fire action"
}

test_action_only_on_escalation

# ── (h) CLI commands ──────────────────────────────────────────────────────

test_cli_evaluate_signals() {
  local output
  output=$("$BREAKER_CLI" evaluate --signals --repeat-count 8 --repeat-tool read --progressing 1)
  assert_contains "$output" "steer" "CLI --signals evaluate returns steer"
  pass "CLI evaluate --signals works"
}

test_cli_status_reset() {
  local state_dir="$TMP_ROOT/state"
  mkdir -p "$state_dir"
  SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" reset test-task >/dev/null
  local status
  status=$(SQUAD_STATE_OVERRIDE="$state_dir" "$BREAKER_CLI" status test-task)
  [ "$status" = "healthy" ] || fail "reset should set healthy, got: $status"
  pass "CLI reset and status work"
}

test_cli_evaluate_signals
test_cli_status_reset

# ── (i) shellcheck-clean ──────────────────────────────────────────────────

test_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --norc "$BREAKER_LIB" || fail "shellcheck failed on sq-breaker-lib.sh"
    shellcheck --norc "$BREAKER_CLI" || fail "shellcheck failed on sq-breaker.sh"
    pass "shellcheck passes on breaker scripts"
  else
    pass "shellcheck not available (skipped)"
  fi
}

test_shellcheck

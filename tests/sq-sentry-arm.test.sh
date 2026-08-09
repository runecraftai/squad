#!/usr/bin/env bash
# tests/sq-sentry-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The sentry prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "sentry: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/sq-sentry.sh holds the singleton, a real bin/sq-sentry-arm.sh attaches to it,
# and a real status change drives a real wake through the sentry-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/stand-to-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/stand-to-helpers.sh"

WATCH="$ROOT/bin/sq-sentry.sh"
WATCH_ARM="$ROOT/bin/sq-sentry-arm.sh"
DRAIN="$ROOT/bin/sq-stand-to-drain.sh"

TMP_ROOT=$(fm_test_tmproot sq-sentry-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real sentry as the singleton holder.
start_seed_sentry() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=5 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.sentry.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-sentry-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.sentry.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed sentry did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_ARM_ATTACH_POLL=0.1 \
    SQUAD_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "sentry: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "sentry: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live sentry: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_sentry "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real commander-relevant status change: the sentry records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed sentry did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.stand-to-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'sentry: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "sentry-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_sentry "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the sentry's identity-bound terminal record
  # still proves which cycle delivered the reason.
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.stand-to-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'sentry: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "sentry-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_sentry "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed sentry remains uninvolved, so only sentry-bound evidence can
  # distinguish this from a delivered sentry cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'sentry: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "sentry-arm: a cycle that delivered no wake of its own still fails loudly"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver

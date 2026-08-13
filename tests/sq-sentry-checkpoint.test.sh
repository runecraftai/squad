#!/usr/bin/env bash
# Tests for bounded foreground sentry checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/sq-sentry-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot sq-sentry-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  SQUAD_BASE="$home" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.sentry.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  SQUAD_BASE="$home" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(SQUAD_BASE="$home" "$ROOT/bin/sq-stand-to-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real sentry wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_sentry_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' sq-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' sq-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with SQUAD_CHECK_INTERVAL=%s\n' "${SQUAD_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  SQUAD_BASE="$home" "$ROOT/bin/sq-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  SQUAD_BASE="$home" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "SQUAD_CHECK_INTERVAL=1" "sentry environment was not preserved"
  pass "checkpoint preserves sentry environment for registered custom checks"
}

test_existing_singleton_sentry_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' sq-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' sq-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.sentry.lock"
  printf '%s\n' "$$" > "$home/state/.sentry.lock/pid"
  status=0
  SQUAD_BASE="$home" SQUAD_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "sentry: already running" "singleton sentry output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton sentry failure was not explained"
  pass "checkpoint rejects an existing sentry singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_sentry_environment
test_existing_singleton_sentry_is_not_success

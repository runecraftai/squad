#!/usr/bin/env bash
# Behavior tests for bin/sq-status-notify.sh: the desktop-notification watcher
# that mirrors herdr "blocked/done" wake events to notify-send/mako with a
# tmux focus action. notify-send and tmux are stubbed with fakebin scripts,
# so the suite is hermetic: no desktop daemon, no tmux server, no network.
# The watcher's public `scan` interface is driven against fake base dirs of
# .status/.meta files; every assertion is on behavior (which notifications
# fire, what the click does), never on the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot sq-status-notify-tests)

BASE_PATH=${SQUAD_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The watcher's per-base offsets live under XDG_STATE_HOME; tests point it at
# a fresh shared root with one mangled subdir per distinct base dir name.
STATE_ROOT="$TMP_ROOT/state"

# A fakebin `notify-send` that records its argv to FAKE_NOTIFY_LOG and, when
# FAKE_NOTIFY_CLICK=1, answers `default` - the click the real daemon listens
# for. Args are bracketed so space-bearing titles and action labels stay
# unambiguous in the log.
make_fake_notify() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/notify-send" <<'SH'
#!/usr/bin/env bash
{
  printf 'notify-send'
  for a in "$@"; do
    printf ' <%s>' "$a"
  done
  printf '\n'
} >> "${FAKE_NOTIFY_LOG:?}"
if [ "${FAKE_NOTIFY_CLICK:-}" = 1 ]; then
  printf 'default\n'
fi
SH
  chmod +x "$fakebin/notify-send"
  printf '%s\n' "$fakebin"
}

# A fakebin `tmux`: `display -p -F` reports the currently focused window
# (FAKE_TMUX_FOCUSED, empty = outside any tmux server), `display-message`
# records its argv to FAKE_TMUX_LOG like the status-line channel, and
# `select-window` records its argv to FAKE_TMUX_LOG exactly like the real
# focus action.
make_fake_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display)
    printf '%s\n' "${FAKE_TMUX_FOCUSED:-}"
    ;;
  display-message)
    {
      printf 'display-message'
      for a in "$@"; do
        printf ' <%s>' "$a"
      done
      printf '\n'
    } >> "${FAKE_TMUX_LOG:?}"
    ;;
  select-window)
    {
      printf 'select-window'
      for a in "$@"; do
        printf ' <%s>' "$a"
      done
      printf '\n'
    } >> "${FAKE_TMUX_LOG:?}"
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_base() {  # <name> -> a fake Squad base with a state/ dir
  local base="$TMP_ROOT/$1"
  mkdir -p "$base/state"
  printf '%s\n' "$base"
}

# Notifications with a meta-derived tmux target fire from a backgrounded
# subshell (the watcher's never-block-on-popup design), so tests must wait a
# bounded moment for the forked side effect instead of racing it.
wait_for_file() {  # <path>: polls up to ~3s for the file to exist
  local path=$1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$path" ] && return 0
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------------------

test_baseline_no_spam() {
  local base fakebin notify_log rc
  base=$(make_base baseline)
  fakebin=$(make_fake_notify "$base")
  notify_log="$base/notify.log"
  printf 'working: first steps\n' > "$base/state/sq-1.status"

  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"; rc=$?
  expect_code 0 "$rc" "baseline scan exit"
  assert_absent "$notify_log" "a first-seen status file must not notify its history"

  printf 'done: baseline done\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"; rc=$?
  expect_code 0 "$rc" "post-baseline scan exit"
  assert_grep "Operator finished: sq-1" "$notify_log" \
    "a new appended line after the baseline must notify"
  assert_grep "<baseline done>" "$notify_log" "the notification must carry the new line's text"
  pass "sq-status-notify baselines pre-existing history and notifies only new lines"
}

test_notifies_each_verb() {
  local base fakebin notify_log count
  base=$(make_base verbs)
  fakebin=$(make_fake_notify "$base")
  notify_log="$base/notify.log"
  printf 'working: seed\n' > "$base/state/sq-1.status"

  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: finished work\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'needs-decision: pick a path\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'blocked: stuck on x\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'failed: test run crashed\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"

  assert_grep "Operator finished: sq-1" "$notify_log" "done must notify"
  assert_grep "Operator needs your decision: sq-1" "$notify_log" "needs-decision must notify"
  assert_grep "Operator blocked: sq-1" "$notify_log" "blocked must notify"
  assert_grep "Work failed: sq-1" "$notify_log" "failed must notify"

  printf 'working: progress note\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  count=$(grep -c '^notify-send' "$notify_log")
  expect_code 4 "$count" "non-notified verb must not add a notification"
  pass "sq-status-notify notifies done, needs-decision, blocked, and failed"
}

test_verb_override() {
  local base fakebin notify_log count
  base=$(make_base verb-override)
  fakebin=$(make_fake_notify "$base")
  notify_log="$base/notify.log"
  printf 'working: seed\n' > "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    SQ_NOTIFY_VERBS="done" "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: x\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    SQ_NOTIFY_VERBS="done" "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'blocked: y\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    SQ_NOTIFY_VERBS="done" "$ROOT/bin/sq-status-notify.sh" scan "$base"

  count=$(grep -c '^notify-send' "$notify_log")
  expect_code 1 "$count" "SQ_NOTIFY_VERBS must narrow the notified verb set"
  assert_grep "Operator finished: sq-1" "$notify_log" "the kept verb must still notify"
  assert_no_grep "Operator blocked: sq-1" "$notify_log" "the dropped verb must not notify"
  pass "sq-status-notify honors the SQ_NOTIFY_VERBS override"
}

test_truncation_reset() {
  local base fakebin notify_log count
  base=$(make_base truncation)
  fakebin=$(make_fake_notify "$base")
  notify_log="$base/notify.log"
  printf 'working: seed\n' > "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: first\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"

  # Rotate/truncate the status file: the offset resets without re-notifying
  # the rewritten content, then a fresh appended line notifies again.
  printf 'working: fresh start\n' > "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  count=$(grep -c '^notify-send' "$notify_log")
  expect_code 1 "$count" "a truncated status file must reset without re-notifying"
  assert_no_grep "fresh start" "$notify_log" "rewritten content must become the new baseline"

  printf 'failed: boom\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  count=$(grep -c '^notify-send' "$notify_log")
  expect_code 2 "$count" "a line appended after truncation must notify"
  assert_grep "Work failed: sq-1" "$notify_log" "the post-truncation event must notify"
  pass "sq-status-notify resets the offset on truncation without spamming history"
}

test_focused_window_suppression() {
  local base fakebin notify_log tmux_log
  base=$(make_base focused)
  fakebin=$(make_fake_notify "$base")
  make_fake_tmux "$base" >/dev/null
  notify_log="$base/notify.log"
  tmux_log="$base/tmux.log"
  printf 'window=Squad:sq-9\n' > "$base/state/sq-9.meta"
  printf 'working: seed\n' > "$base/state/sq-9.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" FAKE_TMUX_FOCUSED="Squad:sq-9" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: finished\n' >> "$base/state/sq-9.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" FAKE_TMUX_FOCUSED="Squad:sq-9" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  assert_absent "$notify_log" "a done event for the already-focused window must be suppressed"

  printf 'failed: then broke\n' >> "$base/state/sq-9.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" FAKE_TMUX_FOCUSED="Other:elsewhere" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  wait_for_file "$notify_log" || fail "the forked notification never landed"
  assert_grep "Work failed: sq-9" "$notify_log" \
    "a different focused window must still notify"
  pass "sq-status-notify suppresses notifications for the focused operator window"
}

test_base_resolution_chain() {
  local base_a base_b fakebin notify_log rc
  base_a=$(make_base chain-arg-a)
  base_b=$(make_base chain-arg-b)
  fakebin=$(make_fake_notify "$base_a")
  notify_log="$base_a/notify.log"

  # Explicit BASE argument wins over SQUAD_BASE: baseline base_a first so its
  # appended event is a new line, then scan it by name while SQUAD_BASE points
  # at base_b.
  printf 'working: seed\n' > "$base_a/state/sq-a.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base_a"
  printf 'done: from a\n' >> "$base_a/state/sq-a.status"
  printf 'done: from b\n' > "$base_b/state/sq-b.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    SQUAD_BASE="$base_b" "$ROOT/bin/sq-status-notify.sh" scan "$base_a"
  assert_grep "sq-a" "$notify_log" "the explicit base argument must win over SQUAD_BASE"
  assert_no_grep "sq-b" "$notify_log" "the ignored base must not notify"

  # SQUAD_BASE wins over the legacy SQUAD_HOME, with no base argument.
  local base_c base_d fakebin_c notify_log_c
  base_c=$(make_base chain-base-a)
  base_d=$(make_base chain-base-b)
  fakebin_c=$(make_fake_notify "$base_c")
  notify_log_c="$base_c/notify.log"
  printf 'working: seed\n' > "$base_c/state/sq-c.status"
  PATH="$fakebin_c:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log_c" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base_c"
  printf 'done: from c\n' >> "$base_c/state/sq-c.status"
  printf 'done: from d\n' > "$base_d/state/sq-d.status"
  PATH="$fakebin_c:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log_c" \
    SQUAD_BASE="$base_c" SQUAD_HOME="$base_d" "$ROOT/bin/sq-status-notify.sh" scan
  assert_grep "sq-c" "$notify_log_c" "SQUAD_BASE must win over the legacy SQUAD_HOME"
  assert_no_grep "sq-d" "$notify_log_c" "the SQUAD_HOME base must not notify when SQUAD_BASE is set"

  # No SQUAD_BASE/SQUAD_HOME: resolve to this repo root and scan it cleanly
  # (the worktree's gitignored state dir holds no status files, so the pass
  # must be silent and notify nothing).
  local notify_log_root
  notify_log_root="$TMP_ROOT/root-fallback.log"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log_root" \
    env -u SQUAD_BASE -u SQUAD_HOME "$ROOT/bin/sq-status-notify.sh" scan; rc=$?
  expect_code 0 "$rc" "repo-root fallback scan exit"
  assert_absent "$notify_log_root" "a scan of the repo root must notify nothing"
  pass "sq-status-notify resolves BASE as argument > SQUAD_BASE > SQUAD_HOME > repo root"
}

test_click_action_focuses_window_from_meta() {
  local base fakebin notify_log tmux_log
  base=$(make_base click)
  fakebin=$(make_fake_notify "$base")
  make_fake_tmux "$base" >/dev/null
  notify_log="$base/notify.log"
  tmux_log="$base/tmux.log"
  printf 'window=Squad:sq-77\n' > "$base/state/sq-77.meta"
  printf 'working: seed\n' > "$base/state/sq-77.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: ready for review\n' >> "$base/state/sq-77.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" FAKE_NOTIFY_CLICK=1 \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"

  wait_for_file "$notify_log" || fail "the notification never landed"
  assert_grep "<default=Focus window>" "$notify_log" \
    "the notification must carry the tmux focus action"
  wait_for_file "$tmux_log" || fail "the click handler never focused the window"
  assert_grep "<select-window> <-t> <Squad:sq-77>" "$tmux_log" \
    "clicking the notification must focus the operator window from window= in the meta"
  pass "sq-status-notify derives the click focus target from window= in <id>.meta"
}

test_focus_requires_target() {
  local fakebin rc
  fakebin=$(fm_fakebin "$TMP_ROOT/focus-usage")
  PATH="$fakebin:$BASE_PATH" "$ROOT/bin/sq-status-notify.sh" focus \
    2>"$TMP_ROOT/focus-usage.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "focus without a target must fail closed"
  assert_grep "usage: sq-status-notify.sh focus TARGET" "$TMP_ROOT/focus-usage.err" \
    "the failure must name the missing target argument"
  pass "sq-status-notify focus fails closed without a target"
}

test_unknown_subcommand_fails_closed() {
  local fakebin rc
  fakebin=$(fm_fakebin "$TMP_ROOT/bad-sub")
  PATH="$fakebin:$BASE_PATH" "$ROOT/bin/sq-status-notify.sh" bogus \
    2>"$TMP_ROOT/bad-sub.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown subcommand must fail closed"
  assert_grep "usage: sq-status-notify.sh watch|scan [BASE] | focus TARGET" \
    "$TMP_ROOT/bad-sub.err" "the failure must print the usage line"
  pass "sq-status-notify fails closed on an unknown subcommand"
}

test_timeout_per_verb() {
  local base fakebin notify_log zero fifteen
  base=$(make_base timeouts)
  fakebin=$(make_fake_notify "$base")
  notify_log="$base/notify.log"
  printf 'working: seed\n' > "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: finished work\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'needs-decision: pick a path\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'blocked: stuck on x\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'failed: test run crashed\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"

  zero=$(grep -cF '<-t> <0>' "$notify_log")
  expect_code 3 "$zero" "needs-decision, blocked, and failed must persist until dismissed"
  fifteen=$(grep -cF '<-t> <15000>' "$notify_log")
  expect_code 1 "$fifteen" "done must show for 15 seconds"
  pass "sq-status-notify persists needs-decision/blocked/failed and times out conclusions"
}

test_stderr_notify_log() {
  local base fakebin notify_log scan_err
  base=$(make_base stderr-log)
  fakebin=$(make_fake_notify "$base")
  notify_log="$base/notify.log"
  scan_err="$base/scan.err"
  printf 'working: seed\n' > "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base" 2>>"$scan_err"
  printf 'done: finished work\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base" 2>>"$scan_err"
  printf 'blocked: stuck on x\n' >> "$base/state/sq-1.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    "$ROOT/bin/sq-status-notify.sh" scan "$base" 2>>"$scan_err"

  assert_grep "notify: Operator finished: sq-1" "$scan_err" "a done event must log its title to stderr"
  assert_grep "notify: Operator blocked: sq-1" "$scan_err" "a blocked event must log its title to stderr"
  pass "sq-status-notify logs each notification title to stderr"
}

test_tmux_channel_target_window() {
  local base fakebin notify_log tmux_log
  base=$(make_base tmux-target)
  fakebin=$(make_fake_notify "$base")
  make_fake_tmux "$base" >/dev/null
  notify_log="$base/notify.log"
  tmux_log="$base/tmux.log"
  printf 'window=Squad:sq-7\n' > "$base/state/sq-7.meta"
  printf 'working: seed\n' > "$base/state/sq-7.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" SQ_NOTIFY_TMUX=1 "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: ready\n' >> "$base/state/sq-7.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" FAKE_TMUX_FOCUSED="Other:elsewhere" SQ_NOTIFY_TMUX=1 \
    "$ROOT/bin/sq-status-notify.sh" scan "$base"

  wait_for_file "$notify_log" || fail "the desktop notification never landed"
  assert_grep "<display-message> <-t> <Squad:sq-7> <Operator finished: sq-7>" "$tmux_log" \
    "the tmux channel must flash on the operator's recorded window"
  assert_grep "Operator finished: sq-7" "$notify_log" \
    "the tmux channel must not replace the desktop notification"
  pass "sq-status-notify flashes the tmux status line on the operator window when enabled"
}

test_tmux_channel_no_target() {
  local base fakebin notify_log tmux_log
  base=$(make_base tmux-no-target)
  fakebin=$(make_fake_notify "$base")
  make_fake_tmux "$base" >/dev/null
  notify_log="$base/notify.log"
  tmux_log="$base/tmux.log"
  printf 'working: seed\n' > "$base/state/sq-3.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" SQ_NOTIFY_TMUX=1 "$ROOT/bin/sq-status-notify.sh" scan "$base"
  printf 'done: ready\n' >> "$base/state/sq-3.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    FAKE_TMUX_LOG="$tmux_log" SQ_NOTIFY_TMUX=1 "$ROOT/bin/sq-status-notify.sh" scan "$base"

  assert_grep "<display-message> <Operator finished: sq-3>" "$tmux_log" \
    "the tmux channel must flash on the calling client's status line without a target"
  assert_grep "Operator finished: sq-3" "$notify_log" \
    "the desktop notification must still fire without a target"
  pass "sq-status-notify flashes the tmux status line without a recorded window"
}

test_tmux_channel_without_tmux() {
  local base fakebin notify_log scan_err rc
  base=$(make_base tmux-missing)
  fakebin=$(make_fake_notify "$base") # no tmux stub: the channel must fail silently
  notify_log="$base/notify.log"
  scan_err="$base/scan.err"
  printf 'working: seed\n' > "$base/state/sq-4.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    SQ_NOTIFY_TMUX=1 "$ROOT/bin/sq-status-notify.sh" scan "$base" 2>"$scan_err"; rc=$?
  expect_code 0 "$rc" "a scan with the tmux channel and no tmux must not fail"
  printf 'done: ready\n' >> "$base/state/sq-4.status"
  PATH="$fakebin:$BASE_PATH" XDG_STATE_HOME="$STATE_ROOT" FAKE_NOTIFY_LOG="$notify_log" \
    SQ_NOTIFY_TMUX=1 "$ROOT/bin/sq-status-notify.sh" scan "$base" 2>"$scan_err"; rc=$?
  expect_code 0 "$rc" "a notification with the tmux channel and no tmux must not fail"
  assert_grep "Operator finished: sq-4" "$notify_log" "notify-send must still fire without tmux"
  assert_grep "notify: Operator finished: sq-4" "$scan_err" "the journal line must still be emitted"
  assert_no_grep "tmux" "$scan_err" "a missing tmux must fail silently"
  pass "sq-status-notify fails silently when the tmux channel is enabled but tmux is absent"
}

# ---------------------------------------------------------------------------

test_baseline_no_spam
test_notifies_each_verb
test_verb_override
test_truncation_reset
test_focused_window_suppression
test_base_resolution_chain
test_click_action_focuses_window_from_meta
test_focus_requires_target
test_unknown_subcommand_fails_closed
test_timeout_per_verb
test_stderr_notify_log
test_tmux_channel_target_window
test_tmux_channel_no_target
test_tmux_channel_without_tmux

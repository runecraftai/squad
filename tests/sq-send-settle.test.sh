#!/usr/bin/env bash
# sq-send post-submit settle pause (SQUAD_SEND_SETTLE).
#
# sq-send's success only proves the composer cleared - the Enter landed and the
# text was submitted. The harness then takes a beat to spin up the turn before its
# busy footer appears, so an immediate peek after sq-send returns would see the
# stale idle pane. sq-send therefore pauses SQUAD_SEND_SETTLE seconds (default 1, 0
# disables) after a successful text submit, so the receiving turn has time to
# visibly start. These tests pin that behavior hermetically (stubbed tmux + sleep,
# no real agent):
#   1. A successful text send pauses for the SQUAD_SEND_SETTLE value (default 1).
#   2. SQUAD_SEND_SETTLE=0 produces no pause at all (sleep is never invoked for it).
#   3. The pause is tunable (SQUAD_SEND_SETTLE=7 pauses 7).
#   4. The --key path never pauses (it bypasses the submit/settle path entirely).
#   5. A native recipient that takes the request and disappears before answering is
#      reported unconfirmed and the instruction is never retyped through the terminal.
#   6. A recipient identifier reused by a different process is no proof about the
#      in-flight instruction: it receives nothing through the dropbox and the in-flight
#      text is never typed through the terminal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-busy-lib.sh"

SEND="$ROOT/bin/sq-send.sh"

TMP_ROOT=$(fm_test_tmproot sq-send-settle)

# A fake tmux that lets sq-send's submit path reach a clean "empty" verdict, plus a
# fake sleep that records every requested duration (one per line) instead of
# sleeping. send-keys always succeeds; display-message yields a numeric cursor_y;
# capture-pane returns an empty bordered composer so fm_tmux_composer_state reads
# "empty" (submit landed) on the first Enter. The sleep log path comes from
# SQUAD_SLEEP_LOG.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ -z "${SQUAD_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$SQUAD_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$SQUAD_SLEEP_LOG"
if [ "${SQUAD_REAL_SLEEP:-0}" = 1 ]; then
  /usr/bin/sleep "${1:-0}"
fi
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <sleep-log> [env-assignments...] -- <sq-send args...>
# Runs sq-send.sh with the stubs on PATH. SQUAD_ROOT_OVERRIDE points at a non-repo
# temp dir so sq-guard's tangle check stays silent, and SQUAD_BASE at an empty home so
# no in-flight task is seen; guard noise goes to stderr (discarded). Echoes nothing;
# returns sq-send's exit code.
run_send() {
  local fb=$1 log=$2 home; shift 2
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  : > "$log"
  env "$@" PATH="$fb:$PATH" \
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$log" \
    "$SEND" "sess:win" "hello commander" 2>/dev/null
}

test_default_send_pauses_one_second() {
  local dir fb log rc last
  dir="$TMP_ROOT/default"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log"; rc=$?
  expect_code 0 "$rc" "default send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 1 ] || fail "default send: expected a trailing 1s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "sq-send: a successful text send pauses the default 1s after submit"
}

test_zero_disables_pause() {
  local dir fb log rc
  dir="$TMP_ROOT/zero"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" SQUAD_SEND_SETTLE=0; rc=$?
  expect_code 0 "$rc" "SQUAD_SEND_SETTLE=0 send should succeed"
  # The disable path must not invoke sleep with 0 at all - the only sleeps left are
  # the submit core's own settle/enter waits, none of which is "0".
  if grep -qx '0' "$log"; then
    fail "SQUAD_SEND_SETTLE=0 still paused (a sleep 0 was recorded)"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  fi
  pass "sq-send: SQUAD_SEND_SETTLE=0 produces no settle pause"
}

test_pause_is_tunable() {
  local dir fb log rc last
  dir="$TMP_ROOT/tunable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" SQUAD_SEND_SETTLE=7; rc=$?
  expect_code 0 "$rc" "SQUAD_SEND_SETTLE=7 send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 7 ] || fail "SQUAD_SEND_SETTLE=7: expected a trailing 7s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "sq-send: the settle pause is tunable via SQUAD_SEND_SETTLE"
}

test_key_path_never_pauses() {
  local dir fb log rc home
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$log" \
    "$SEND" "sess:win" --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "--key send should succeed"
  [ ! -s "$log" ] || fail "--key path paused but must not"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "sq-send: the --key path never pauses (settle scoped to text submit)"
}

test_pi_native_delivery_avoids_tmux_for_parked_operator() {
  local dir fb log home delivery processor pid ready_identity message rc task_id
  dir="$TMP_ROOT/pi-native"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state" "$home/project"
  task_id=task.with.dot
  fm_write_meta "$home/state/$task_id.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=pi" "kind=strike" "mode=drill" "yolo=off"
  delivery="$home/state/.pi-delivery/$task_id"; mkdir -p "$delivery"
  processor="$dir/process-delivery.sh"
  cat > "$processor" <<'SH'
#!/usr/bin/env bash
set -u
dir=$1
log=$2
while :; do
  for request in "$dir"/*.request; do
    [ -e "$request" ] || continue
    request_id=$(basename "$request" .request)
    {
      IFS= read -r _request_line
      IFS= read -r message
    } < "$request"
    printf '%s\n' "$message" >> "$log"
    printf 'delivered\n' > "$dir/$request_id.response"
    rm -f "$request"
  done
  /usr/bin/sleep 0.01
done
SH
  chmod +x "$processor"
  "$processor" "$delivery" "$dir/native-message" &
  pid=$!
  ready_identity=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s\n%s\n' "$pid" "ps-lstart=$ready_identity" > "$delivery/ready"
  message='native parked steer'
  out=$(env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$log" \
    SQUAD_TMUX_LOG="$dir/tmux.log" SQUAD_REAL_SLEEP=1 SQUAD_SEND_SETTLE=0 \
    SQUAD_PROC_ROOT_OVERRIDE="$home/no-proc" SQUAD_PI_DELIVERY_TIMEOUT=3 \
    "$SEND" "$task_id" "$message" 2>/dev/null)
  rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "Pi native delivery should succeed"
  assert_contains "$out" "Pi queued the instruction; consumption is not confirmed." \
    "sq-send did not distinguish queued delivery from confirmed consumption"
  [ "$(cat "$dir/native-message")" = "$message" ] \
    || fail "Pi native delivery did not preserve the message"
  [ "$(wc -l < "$dir/native-message")" -eq 1 ] \
    || fail "Pi native delivery delivered the steer more than once"
  [ ! -s "$dir/tmux.log" ] || fail "Pi native delivery unexpectedly used tmux"
  pass "sq-send: accepted Pi follow-ups report success and arrive exactly once"
}

test_pi_native_failure_names_dropbox_path() {
  local dir fb home delivery processor pid ready_identity err rc task_id
  dir="$TMP_ROOT/pi-native-failure"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state" "$home/project"
  task_id=task-native-failure
  fm_write_meta "$home/state/$task_id.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=pi" "kind=strike" "mode=drill" "yolo=off"
  delivery="$home/state/.pi-delivery/$task_id"; mkdir -p "$delivery"
  processor="$dir/process-delivery.sh"
  cat > "$processor" <<'SH'
#!/usr/bin/env bash
set -u
dir=$1
while :; do
  for request in "$dir"/*.request; do
    [ -e "$request" ] || continue
    request_id=$(basename "$request" .request)
    printf 'unconfirmed\n' > "$dir/$request_id.response"
    rm -f "$request"
  done
  /usr/bin/sleep 0.01
done
SH
  chmod +x "$processor"
  "$processor" "$delivery" &
  pid=$!
  ready_identity=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s\n%s\n' "$pid" "ps-lstart=$ready_identity" > "$delivery/ready"
  err="$dir/send.err"
  env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SEND_SETTLE=0 \
    SQUAD_PROC_ROOT_OVERRIDE="$home/no-proc" SQUAD_PI_DELIVERY_TIMEOUT=3 \
    "$SEND" "$task_id" 'native failure' >/dev/null 2>"$err"; rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "an unconfirmed native Pi delivery reported success"
  assert_contains "$(cat "$err")" "native Pi dropbox" \
    "native delivery failure did not name the failed dropbox path"
  assert_not_contains "$(cat "$err")" "tmux send failed" \
    "native delivery failure was mislabeled as a tmux failure"
  pass "sq-send: native Pi failures identify the dropbox path"
}

test_pi_fallback_to_tmux_when_extension_unavailable() {
  local dir fb log home rc
  dir="$TMP_ROOT/pi-fallback"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state" "$home/project"
  fm_write_meta "$home/state/task.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=pi-signed" "kind=strike" "mode=drill" "yolo=off"
  env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$log" \
    SQUAD_TMUX_LOG="$dir/tmux.log" SQUAD_SEND_SETTLE=0 \
    "$SEND" task "fallback steer" 2>/dev/null
  rc=$?
  expect_code 0 "$rc" "Pi fallback delivery should succeed"
  [ -s "$dir/tmux.log" ] || fail "Pi extension fallback did not use tmux"
  pass "sq-send: Pi falls back to tmux when native delivery is unavailable"
}

test_claude_escape_records_interrupt_idle() {
  local dir fb log rc home gen out
  dir="$TMP_ROOT/claude-interrupt"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/task.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=claude" "kind=strike" "mode=drill" "yolo=off"
  gen=$("$ROOT/bin/sq-busy-event.sh" arm "$home/state" task)
  printf 'busy_gen=%s\n' "$gen" >> "$home/state/task.meta"
  : > "$log"

  env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$log" \
    "$SEND" task --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "Claude Escape send should succeed"
  out=$(fm_busy_classify tmux sess:win claude task "$home/state")
  [ "$out" = "idle sq-interrupt" ] \
    || fail "Claude Escape must classify idle/sq-interrupt, got '$out'"
  pass "sq-send: a successful Claude Escape records the interrupt lifecycle edge"
}

test_default_send_pauses_one_second
test_zero_disables_pause
test_pause_is_tunable
test_key_path_never_pauses
test_pi_native_delivery_avoids_tmux_for_parked_operator
test_pi_native_failure_names_dropbox_path
test_pi_fallback_to_tmux_when_extension_unavailable
# make_lost_recipient_sleep <fakebin>: replaces the fake sleep with a stand-in native
# recipient that takes an admitted request and never answers. sq-send polls sleep from
# its native wait loop after the request is already in the dropbox, so that call is the
# controlled point that hands the request over; the terminal fallback's own settle and
# enter waits reach the same stub and find nothing left to take. The stand-in marks
# each request it takes (so one request is logged once), logs its message, removes the
# registration so the recipient visibly goes away, and leaves the request in the
# dropbox unanswered, exactly as the production path does for an unconfirmed send.
# Termination is sq-send's own SQUAD_PI_DELIVERY_TIMEOUT deadline, not this stub, and
# no assertion depends on how long that takes. Inputs: SQUAD_RECIPIENT_DIR (the
# dropbox), SQUAD_RECIPIENT_LOG (delivered messages), SQUAD_RECIPIENT_READY (the
# registration).
make_lost_recipient_sleep() {  # <fakebin>
  cat > "$1/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$SQUAD_SLEEP_LOG"
for request in "$SQUAD_RECIPIENT_DIR"/*.request; do
  [ -e "$request" ] || continue
  [ ! -e "$request.taken" ] || continue
  {
    IFS= read -r _request_id
    IFS= read -r message
  } < "$request"
  printf '%s\n' "$message" >> "$SQUAD_RECIPIENT_LOG"
  : > "$request.taken"
  rm -f "$SQUAD_RECIPIENT_READY"
done
exit 0
SH
  chmod +x "$1/sleep"
}

# lost_native_task <dir> <task-id>: a Pi task whose dropbox is registered to this shell
# with its live start identity, so sq-send's identity check admits the native path.
# Echoes the dropbox dir.
lost_native_task() {
  local dir=$1 task_id=$2 home delivery ready_identity
  home="$dir/home"; mkdir -p "$home/state" "$home/project"
  fm_write_meta "$home/state/$task_id.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=pi" "kind=strike" "mode=drill" "yolo=off"
  delivery="$home/state/.pi-delivery/$task_id"; mkdir -p "$delivery"
  ready_identity=$(LC_ALL=C ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s\n%s\n' "$$" "ps-lstart=$ready_identity" > "$delivery/ready"
  printf '%s\n' "$delivery"
}

test_lost_native_response_is_never_retyped() {
  local dir fb home delivery message out err rc pending
  dir="$TMP_ROOT/pi-lost-response"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); make_lost_recipient_sleep "$fb"
  home="$dir/home"
  delivery=$(lost_native_task "$dir" task-lost-response)
  message='lost native steer'
  err="$dir/send.err"
  : > "$dir/recipient.log"; : > "$dir/tmux.log"
  out=$(env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$dir/sleep.log" \
    SQUAD_TMUX_LOG="$dir/tmux.log" SQUAD_SEND_SETTLE=0 \
    SQUAD_RECIPIENT_DIR="$delivery" SQUAD_RECIPIENT_LOG="$dir/recipient.log" \
    SQUAD_RECIPIENT_READY="$delivery/ready" \
    SQUAD_PROC_ROOT_OVERRIDE="$home/no-proc" SQUAD_PI_DELIVERY_TIMEOUT=1 \
    "$SEND" task-lost-response "$message" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "a native send that never got an answer reported success"
  [ -z "$out" ] || fail "a native send that never got an answer printed a success line"$'\n'"--- stdout ---"$'\n'"$out"
  assert_contains "$(cat "$err")" "native Pi dropbox" \
    "lost native response did not name the native dropbox"
  [ "$(cat "$dir/recipient.log")" = "$message" ] \
    || fail "the native recipient did not take the instruction exactly once"$'\n'"--- delivered ---"$'\n'"$(cat "$dir/recipient.log")"
  pending=$(find "$delivery" -name '*.request' -type f)
  [ "$(find "$delivery" -name '*.request' -type f | wc -l)" -eq 1 ] \
    || fail "the unconfirmed native request was not left in the dropbox for reconciliation"$'\n'"--- dropbox ---"$'\n'"$(ls -A "$delivery")"
  [ "$(sed -n '2p' "$pending")" = "$message" ] \
    || fail "the request left in the dropbox is not the unconfirmed instruction"$'\n'"--- pending ---"$'\n'"$(cat "$pending")"
  [ ! -f "${pending%.request}.response" ] \
    || fail "a native send that never got an answer was recorded as answered"$'\n'"--- dropbox ---"$'\n'"$(ls -A "$delivery")"
  [ ! -s "$dir/tmux.log" ] \
    || fail "a lost native response was retyped through the terminal"$'\n'"--- tmux ---"$'\n'"$(cat "$dir/tmux.log")"
  pass "sq-send: a lost native response is reported unconfirmed and never retyped through the terminal"
}

test_reused_recipient_identifier_is_no_proof() {
  local dir fb home delivery in_flight follow_up out err err2 rc rc2 pending
  dir="$TMP_ROOT/pi-reused-recipient"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); make_lost_recipient_sleep "$fb"
  home="$dir/home"
  delivery=$(lost_native_task "$dir" task-reused-recipient)
  in_flight='in-flight steer'
  follow_up='follow-up steer'
  err="$dir/send.err"; err2="$dir/followup.err"
  : > "$dir/recipient.log"; : > "$dir/tmux.log"

  # 1. The in-flight instruction is admitted, taken by the recipient, and never answered.
  env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$dir/sleep.log" \
    SQUAD_TMUX_LOG="$dir/tmux.log" SQUAD_SEND_SETTLE=0 \
    SQUAD_RECIPIENT_DIR="$delivery" SQUAD_RECIPIENT_LOG="$dir/recipient.log" \
    SQUAD_RECIPIENT_READY="$delivery/ready" \
    SQUAD_PROC_ROOT_OVERRIDE="$home/no-proc" SQUAD_PI_DELIVERY_TIMEOUT=1 \
    "$SEND" task-reused-recipient "$in_flight" 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fixture: the in-flight native send reported success"
  [ "$(cat "$dir/recipient.log")" = "$in_flight" ] \
    || fail "fixture: the native recipient did not take the in-flight instruction"

  # 2. The recorded recipient identifier is now held by a different process: this
  #    shell's live pid, under a start identity the original recipient never had.
  printf '%s\n%s\n' "$$" "ps-lstart=Thu Jan  1 00:00:00 1970" > "$delivery/ready"

  # 3. A new instruction goes out. The reused identifier must not receive it through
  #    the dropbox, and the in-flight instruction must not be typed again.
  out=$(env PATH="$fb:$PATH" SQUAD_BASE="$home" SQUAD_SLEEP_LOG="$dir/sleep.log" \
    SQUAD_TMUX_LOG="$dir/tmux.log" SQUAD_SEND_SETTLE=0 \
    SQUAD_RECIPIENT_DIR="$delivery" SQUAD_RECIPIENT_LOG="$dir/recipient.log" \
    SQUAD_RECIPIENT_READY="$delivery/ready" \
    SQUAD_PROC_ROOT_OVERRIDE="$home/no-proc" SQUAD_PI_DELIVERY_TIMEOUT=1 \
    "$SEND" task-reused-recipient "$follow_up" 2>"$err2"); rc2=$?
  [ "$(cat "$dir/recipient.log")" = "$in_flight" ] \
    || fail "a reused recipient identifier received a later instruction through the dropbox"$'\n'"--- delivered ---"$'\n'"$(cat "$dir/recipient.log")"
  expect_code 0 "$rc2" "a new instruction should use the terminal fallback once the recorded identity is stale"
  assert_not_contains "$out" "Pi " \
    "a reused recipient identifier was reported as native Pi delivery"
  [ "$(grep -c -- "$follow_up" "$dir/tmux.log")" -eq 1 ] \
    || fail "the new instruction was not typed exactly once through the terminal fallback"$'\n'"--- tmux ---"$'\n'"$(cat "$dir/tmux.log")"
  [ "$(grep -c -- "$in_flight" "$dir/tmux.log")" -eq 0 ] \
    || fail "the in-flight instruction was retyped through the terminal after identifier reuse"$'\n'"--- tmux ---"$'\n'"$(cat "$dir/tmux.log")"
  [ "$(find "$delivery" -name '*.request' -type f | wc -l)" -eq 1 ] \
    || fail "the follow-up instruction was written into the native dropbox after identifier reuse"$'\n'"--- dropbox ---"$'\n'"$(ls -A "$delivery")"
  pending=$(find "$delivery" -name '*.request' -type f)
  [ "$(sed -n '2p' "$pending")" = "$in_flight" ] \
    || fail "the pending dropbox request is not the instruction that was still in flight"$'\n'"--- pending ---"$'\n'"$(cat "$pending")"
  [ ! -f "${pending%.request}.response" ] \
    || fail "the in-flight instruction gained a response after identifier reuse"
  pass "sq-send: a reused recipient identifier is no proof about the in-flight instruction"
}

test_claude_escape_records_interrupt_idle

test_lost_native_response_is_never_retyped
test_reused_recipient_identifier_is_no_proof

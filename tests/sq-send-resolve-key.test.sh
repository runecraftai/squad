#!/usr/bin/env bash
# sq-send answerer-closes (--resolve-key) behavior.
#
# A commander decision opened by a keyed needs-decision:/blocked: status line
# historically stayed open forever when the answer kicked off work: the worker's
# next line is working [key=<workstream>], never resolved [key=<decision>].
# sq-send's --resolve-key removes that writer-dependency at its source: the
# ANSWERING Squad closes the decision in this home's own ledger at answer
# time. These tests drive the real sq-send executable over stubbed transports
# and assert closure through the real consumer (sq-stand-to-drain.sh's OPEN
# DECISIONS section), never through source text:
#   1. An answer send closes the open decision, including the answer-starts-work
#      scenario where the worker never writes a matching resolved line.
#   2. A routine steer without the flag never closes anything, and a working:/
#      done: line still cannot clear a commander decision.
#   3. A key that is not open refuses BEFORE anything is sent (mistype safety).
#   4. A failed or unconfirmed send never closes a key.
#   5. A local XO answer is marked+corr'd yet closes the same way, and
#      the closing line carries the plain answer, not marker or corr bytes.
#   6. A remote XO answer differs only at the transport layer: the
#      message crosses the stubbed ssh transport while the close is the same
#      local ledger append; a failed transport closes nothing.
#   7. Flag misuse (--key, empty message, explicit backend target) refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-marker-lib.sh"

SEND="$ROOT/bin/sq-send.sh"
DRAIN="$ROOT/bin/sq-stand-to-drain.sh"

TMP_ROOT=$(fm_test_tmproot sq-send-resolve-key)

# Stub tmux: logs literal typed text to SQUAD_SEND_LOG and lets the submit path
# reach a clean "empty" verdict (numeric cursor_y, empty bordered composer).
# SQUAD_FAKE_TMUX_SEND_FAIL=1 makes send-keys fail so the delivery-failure leg can
# assert that a failed send closes nothing.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${SQUAD_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$SQUAD_SEND_LOG"
    fi
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
exit 0
SH
  chmod +x "$fb/sleep"
  # Stub ssh transport for the remote-XO legs, selected via SQUAD_SSH_BIN.
  # Records the full remote invocation and exits SQUAD_FAKE_SSH_RC (default 0).
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$SQUAD_SSH_LOG"
exit "${SQUAD_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> <sq-send args...>: run the real sq-send
# with the stubs on PATH against the given home. Guard noise goes to stderr,
# captured per test when the diagnostic matters.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

drain_out() {  # <home>
  SQUAD_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

test_answer_send_closes_open_decision() {
  local dir fb log home rc out
  dir="$TMP_ROOT/closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home closes)
  fm_write_meta "$home/state/t1.meta" "window=sess:sq-t1" "kind=strike"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'working: kept busy on an unrelated stream\n' >> "$home/state/t1.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "precondition: the buried decision should list as open before the answer"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "an answer send with --resolve-key should succeed"
  assert_contains "$(cat "$log")" "go with REST" "the answer text should reach the worker"
  grep -F 'resolved [key=api-shape]: answered: go with REST' "$home/state/t1.status" >/dev/null \
    || fail "sq-send did not append the closing resolved line:"$'\n'"$(cat "$home/state/t1.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open: $out"
  fi
  pass "sq-send --resolve-key: the answer send itself closes the open decision"
}

test_answer_starts_work_never_orphans() {
  local dir fb log home rc out
  dir="$TMP_ROOT/starts-work"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home starts-work)
  fm_write_meta "$home/state/t2.meta" "window=sess:sq-t2" "kind=strike"
  printf 'needs-decision [key=rollout]: big-bang or phased\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --resolve-key rollout "phased, gate each region"; rc=$?
  expect_code 0 "$rc" "the rollout answer send should succeed"
  # The forensic scenario: the answer starts a workstream, so the worker's next
  # events use a DIFFERENT key namespace and it never writes
  # resolved [key=rollout] itself.
  printf 'working [key=phased-impl]: building region gates\n' >> "$home/state/t2.status"
  printf 'done [key=phased-impl]: PR up\n' >> "$home/state/t2.status"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision orphaned after the answer started work: $out"
  fi
  pass "sq-send --resolve-key: an answer that starts a workstream leaves no orphaned decision"
}

test_routine_steer_never_closes() {
  local dir fb log home rc out
  dir="$TMP_ROOT/routine"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home routine)
  fm_write_meta "$home/state/t3.meta" "window=sess:sq-t3" "kind=strike"
  printf 'needs-decision [key=schema]: split or embed\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 "unrelated nudge, keep going"; rc=$?
  expect_code 0 "$rc" "a routine steer should still succeed"
  printf 'working: resumed\n' >> "$home/state/t3.status"
  printf 'done: unrelated milestone\n' >> "$home/state/t3.status"

  if grep -F 'resolved' "$home/state/t3.status" >/dev/null; then
    fail "a routine steer wrote a resolved line: $(cat "$home/state/t3.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=schema]' >/dev/null \
    || fail "a routine steer (or later working/done lines) cleared an unanswered commander decision: $out"
  pass "sq-send: a send without --resolve-key never closes a decision, and working/done still cannot"
}

test_not_open_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/not-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home not-open)
  fm_write_meta "$home/state/t4.meta" "window=sess:sq-t4" "kind=strike"
  printf 'needs-decision [key=real-key]: choose\n' > "$home/state/t4.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t4 --resolve-key mistyped "the answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a not-open key should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'mistyped'" "the refusal should name the bad key"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  if grep -F 'resolved' "$home/state/t4.status" >/dev/null; then
    fail "a refused answer still closed something: $(cat "$home/state/t4.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=real-key]' >/dev/null \
    || fail "the real decision disappeared after a refused answer: $out"
  pass "sq-send --resolve-key: a key that is not open refuses loudly before anything is sent"
}

test_failed_send_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/send-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home send-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:sq-t5" "kind=strike"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" SQUAD_FAKE_TMUX_SEND_FAIL=1 \
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed backend send should exit nonzero"
  if grep -F 'resolved' "$home/state/t5.status" >/dev/null; then
    fail "a failed send still closed the decision: $(cat "$home/state/t5.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker vanished after a failed send: $out"
  pass "sq-send --resolve-key: a failed send never closes the decision"
}

test_multiple_keys_close_together() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi)
  fm_write_meta "$home/state/t6.meta" "window=sess:sq-t6" "kind=strike"
  {
    printf 'needs-decision [key=k1]: first\n'
    printf 'blocked [key=k2]: second\n'
    printf 'needs-decision [key=k3]: third, unanswered\n'
  } > "$home/state/t6.status"

  run_send "$fb" "$home" "$log" t6 --resolve-key k1 --resolve-key k2 \
    "one answer covering both"; rc=$?
  expect_code 0 "$rc" "an answer resolving two keys should succeed"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=k3]' >/dev/null \
    || fail "the unanswered third decision must stay open: $out"
  if printf '%s' "$out" | grep -E '\[key=k1\]|\[key=k2\]' >/dev/null; then
    fail "an answered key is still open after a multi-key answer: $out"
  fi
  pass "sq-send --resolve-key: one answer closes each named key and only those"
}

test_local_XO_answer_marked_and_closed() {
  local dir fb log home rc got out closing
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_XO_meta "$home/state/domain.meta" "$home" "sess:sq-domain"
  printf 'needs-decision [key=unit-split]: shard by team or by repo\n' > "$home/state/domain.status"

  run_send "$fb" "$home" "$log" sq-domain --resolve-key unit-split "shard by team"; rc=$?
  expect_code 0 "$rc" "an XO answer send should succeed"
  got=$(cat "$log")
  case "$got" in
    "$SQUAD_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the XO answer lost its from-squad marker/corr framing" ;;
  esac
  closing=$(grep -F 'resolved [key=unit-split]' "$home/state/domain.status" || true)
  [ -n "$closing" ] || fail "the XO decision was not closed: $(cat "$home/state/domain.status")"
  case "$closing" in
    *corr=*) fail "the closing line leaked the corr token: $closing" ;;
  esac
  case "$closing" in
    *"$SQUAD_FROMFIRST_SEPARATOR"*) fail "the closing line leaked marker bytes" ;;
  esac
  assert_contains "$closing" "shard by team" "the closing line should carry the plain answer"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered XO decision still lists as open: $out"
  fi
  pass "sq-send --resolve-key: a marked local-XO answer closes with the plain answer text"
}

# Remote XO: the answer crosses the (stubbed) ssh transport through the
# real sq-on.sh + registry route, while the close is the SAME local ledger
# append as every other target kind - the transport is the only difference.
setup_remote_home() {  # <name> -> echoes home dir with remote meta + registry
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=sq-remote:w1:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=xo" \
    "mode=xo" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=sq-remote" \
    "remote_target=sq-remote:w1:p1"
  cat > "$home/data/XOs.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

test_remote_XO_answer_closes_locally() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-ok"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-ok)
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    SQUAD_SSH_BIN="$fb/fake-ssh" SQUAD_SSH_LOG="$ssh_log" SQUAD_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote XO answer send should succeed"
  assert_grep 'sq-remote-entrypoint.sh' "$ssh_log" \
    "the answer message should cross the remote transport"
  grep -F 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' "$home/state/rsm.status" >/dev/null \
    || fail "the remote answer did not close the local ledger: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered remote-XO decision still lists as open: $out"
  fi
  pass "sq-send --resolve-key: a remote-XO answer closes the same local ledger, transport-only difference"
}

test_remote_transport_failure_does_not_close() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-fail)
  printf 'blocked [key=quota]: remote host is out of runway\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    SQUAD_SSH_BIN="$fb/fake-ssh" SQUAD_SSH_LOG="$ssh_log" SQUAD_FAKE_SSH_RC=1 \
    "$SEND" rsm --resolve-key quota "quota refreshed, resume" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed remote transport should exit nonzero"
  if grep -F 'resolved' "$home/state/rsm.status" >/dev/null; then
    fail "a failed remote send still closed the decision: $(cat "$home/state/rsm.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=quota]' >/dev/null \
    || fail "the remote blocker vanished after a failed transport: $out"
  pass "sq-send --resolve-key: a failed remote transport never closes the decision"
}

test_flag_misuse_refuses() {
  local dir fb log home err rc
  dir="$TMP_ROOT/misuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home misuse)
  fm_write_meta "$home/state/t7.meta" "window=sess:sq-t7" "kind=strike"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/t7.status"

  # --resolve-key with --key (both orders) is refused: an answer is text.
  : > "$log"
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key before --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"
  : > "$log"
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --key Enter --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key after --key should refuse instead of being silently dropped"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --resolve-key refusal should be explicit"

  # An empty answer message is refused.
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty answer message should refuse"
  assert_contains "$(cat "$err")" "nonempty answer message" "the empty-message refusal should be explicit"

  # An explicit backend target has no task ledger in this home.
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" sess:elsewhere --resolve-key k "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --resolve-key"
  assert_contains "$(cat "$err")" "no decision ledger" "the explicit-target refusal should be explicit"

  # A malformed key is refused before anything else.
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key 'bad key!' "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed key should refuse"
  assert_contains "$(cat "$err")" "not a valid decision key" "the malformed-key refusal should be explicit"

  [ ! -s "$log" ] || fail "a refused misuse still typed text: $(cat "$log")"
  if grep -F 'resolved' "$home/state/t7.status" >/dev/null; then
    fail "a refused misuse still closed something: $(cat "$home/state/t7.status")"
  fi
  pass "sq-send --resolve-key: --key, empty message, explicit targets, and malformed keys refuse loudly"
}

test_answer_send_closes_open_decision
test_answer_starts_work_never_orphans
test_routine_steer_never_closes
test_not_open_key_refuses_before_send
test_failed_send_does_not_close
test_multiple_keys_close_together
test_local_XO_answer_marked_and_closed
test_remote_XO_answer_closes_locally
test_remote_transport_failure_does_not_close
test_flag_misuse_refuses

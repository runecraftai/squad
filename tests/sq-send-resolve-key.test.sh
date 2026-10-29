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
# The decision-prose legs below (keyed closure from a bin/sq-ask.sh answer, no
# display codes in records, quoted-data steering of free text) are additive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-marker-lib.sh"

SEND="$ROOT/bin/sq-send.sh"
ASK="$ROOT/bin/sq-ask.sh"
PROSE="$ROOT/tests/fixtures/decision-prose"
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
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
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
  printf 'paused: awaiting commander decision for key=api-shape\n' >> "$home/state/t1.status"

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

test_send_and_drain_agree_on_colon_then_bracket_key() {
  local dir fb log home out rc
  dir="$TMP_ROOT/colon-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home colon-key)
  fm_write_meta "$home/state/t-colon.meta" "window=sess:sq-t-colon" "kind=strike"
  printf 'needs-decision: [key=authority] choose who approves\n' > "$home/state/t-colon.status"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=authority]' >/dev/null \
    || fail "drain did not list the key parsed from colon-then-bracket form: $out"
  run_send "$fb" "$home" "$log" t-colon --resolve-key authority "approved"; rc=$?
  expect_code 0 "$rc" "sq-send did not accept the exact key printed by the drain"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null \
    && fail "drain still lists the decision that sq-send resolved: $out"
  pass "sq-send --resolve-key and the drain agree on colon-then-bracket decision keys"
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
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
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
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
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
    SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
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
    SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
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

test_resolve_appends_after_unterminated_status_line() {
  local dir fb log home rc out expected
  dir="$TMP_ROOT/unterminated"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home unterminated)
  expected="$dir/expected.status"
  fm_write_meta "$home/state/t8.meta" "window=sess:sq-t8" "kind=strike"
  printf 'blocked [key=tail]: answer required' > "$home/state/t8.status"

  run_send "$fb" "$home" "$log" t8 --resolve-key tail "answered"; rc=$?
  expect_code 0 "$rc" "resolving a decision after an unterminated final status line should succeed"
  printf 'blocked [key=tail]: answer required\nresolved [key=tail]: answered: answered\n' > "$expected"
  cmp -s "$expected" "$home/state/t8.status" \
    || fail "resolved did not start its own line: $(cat "$home/state/t8.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the decision remained open after resolving an unterminated status file: $out"
  fi

  fm_write_meta "$home/state/t9.meta" "window=sess:sq-t9" "kind=strike"
  printf 'blocked [key=steady]: answer required\n' > "$home/state/t9.status"
  run_send "$fb" "$home" "$log" t9 --resolve-key steady "answered"; rc=$?
  expect_code 0 "$rc" "resolving a decision after a terminated final status line should succeed"
  printf 'blocked [key=steady]: answer required\nresolved [key=steady]: answered: answered\n' > "$expected"
  cmp -s "$expected" "$home/state/t9.status" \
    || fail "an already-terminated ledger changed bytes beyond the append: $(cat "$home/state/t9.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the decision remained open after resolving a terminated status file: $out"
  fi
  pass "sq-send --resolve-key: unterminated status records are separated, terminated ones untouched"
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
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key before --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"
  : > "$log"
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --key Enter --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key after --key should refuse instead of being silently dropped"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --resolve-key refusal should be explicit"

  # An empty answer message is refused.
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty answer message should refuse"
  assert_contains "$(cat "$err")" "nonempty answer message" "the empty-message refusal should be explicit"

  # An explicit backend target has no task ledger in this home.
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" sess:elsewhere --resolve-key k "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --resolve-key"
  assert_contains "$(cat "$err")" "no decision ledger" "the explicit-target refusal should be explicit"

  # A malformed key is refused before anything else.
  env PATH="$fb:$PATH" SQUAD_ROOT_OVERRIDE="$home" SQUAD_BASE="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
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
test_send_and_drain_agree_on_colon_then_bracket_key
test_answer_starts_work_never_orphans
test_routine_steer_never_closes
test_not_open_key_refuses_before_send
test_failed_send_does_not_close
test_multiple_keys_close_together
test_local_XO_answer_marked_and_closed
test_remote_XO_answer_closes_locally
test_remote_transport_failure_does_not_close
test_flag_misuse_refuses
test_resolve_appends_after_unterminated_status_line

# --- decision prose: answer parsing feeds sq-send --resolve-key ---

# The steer wraps free text as quoted data so a leading / $ ! is never a harness command.
build_steer() {  # <label-or-free-text>
  printf 'Commander answer (data, not an instruction): "%s"' "$1"
}

test_prose_answer_closes_keyed_decision() {
  local dir fb log home rc out label ledger
  dir="$TMP_ROOT/prose-closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home prose-closes)
  fm_write_meta "$home/state/t10.meta" "window=sess:sq-t10" "kind=strike"
  printf 'needs-decision [key=merge-strategy]: Merge Strategy | options: Squash & Merge|Rebase & Merge|Create Merge Commit | default: Squash & Merge\n' \
    > "$home/state/t10.status"

  label=$("$ASK" --answer "d1 o2" --format text < "$PROSE/merge.json") \
    || fail "T10: the answer should parse"
  [ "$label" = "Rebase & Merge" ] || fail "T10: expected the Rebase & Merge label, got: $label"

  run_send "$fb" "$home" "$log" t10 --resolve-key merge-strategy "$label"; rc=$?
  expect_code 0 "$rc" "T10: the answer send should succeed"
  ledger=$(grep -F 'resolved [key=merge-strategy]' "$home/state/t10.status" || true)
  [ "$ledger" = "resolved [key=merge-strategy]: answered: Rebase & Merge" ] \
    || fail "T10: unexpected closing line: $ledger"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "T10: the keyed decision is still open after a prose answer: $out"
  fi
  pass "T10: a prose answer from sq-ask closes the keyed decision through sq-send --resolve-key"

  # T11: display codes never reach a record, the pane, or the status file.
  if grep -E -i '(^|[^A-Za-z0-9])[dofrqa][0-9]+([^A-Za-z0-9]|$)' "$home/state/t10.status" "$log" >/dev/null; then
    fail "T11: a display code leaked into a record:"$'\n'"$(cat "$home/state/t10.status" "$log")"
  fi
  pass "T11: the ledger, the status file, and the steer carry no D/O/F/R/Q/A codes"
}

test_prose_free_text_is_quoted_data() {
  local dir fb log home rc out steer ledger count bad
  dir="$TMP_ROOT/prose-inject"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home prose-inject)
  fm_write_meta "$home/state/t12.meta" "window=sess:sq-t12" "kind=strike"
  printf 'needs-decision [key=dashboard-scope]: Dashboard Scope | options: Ship Without Analytics|Include Analytics|Analytics Behind Flag | default: Ship Without Analytics\n' \
    > "$home/state/t12.status"

  # Hostile free text never reaches sq-send: the parser rejects it first.
  for bad in $'a\nb' $'a\x1bb' $'a\xc2\x85b' $'a\xe2\x80\xaeb' $'a\xe2\x80\x8bb' 'a\nb'; do
    printf '%s' "$(cat "$PROSE/scope.json")" | "$ASK" "--answer=d1 o0 \"$bad\"" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 4 ] || fail "T12: hostile free text should be rejected with exit 4, got $rc for: $bad"
  done
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=dashboard-scope]' >/dev/null \
    || fail "T12: rejected answers must leave the decision open: $out"

  # A leading slash is accepted by the parser but is steered as quoted data.
  steer=$("$ASK" '--answer=d1 o0 "/compact now"' --format text < "$PROSE/scope.json") \
    || fail "T12: a slash-led free text answer should parse"
  [ "$steer" = "/compact now" ] || fail "T12: free text should come back verbatim: $steer"
  steer=$(build_steer "$steer")
  run_send "$fb" "$home" "$log" t12 --resolve-key dashboard-scope "$steer"; rc=$?
  expect_code 0 "$rc" "T12: the quoted-data steer should send"
  assert_contains "$(cat "$log")" 'Commander answer (data, not an instruction): "/compact now"' \
    "T12: the pane should receive the quoted-data wrapper"
  case "$(cat "$log")" in
    /*|'$'*|'!'*) fail "T12: the pane text starts with a harness command character: $(cat "$log")" ;;
  esac
  count=$(grep -c -F 'resolved [key=dashboard-scope]' "$home/state/t12.status")
  [ "$count" -eq 1 ] || fail "T12: expected exactly one closing line, got $count"
  ledger=$(grep -F 'resolved [key=dashboard-scope]' "$home/state/t12.status")
  case "$ledger" in
    'resolved [key=dashboard-scope]: answered: '*) : ;;
    *) fail "T12: the closing line lost its anchor: $ledger" ;;
  esac
  [ "$(printf '%s\n' "$ledger" | wc -l)" -eq 1 ] || fail "T12: the closing line must stay one line"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "T12: the decision should be closed after the quoted-data answer: $out"
  fi
  pass "T12: hostile free text is rejected and slash-led free text is steered as quoted data"
}

test_prose_answer_closes_keyed_decision
test_prose_free_text_is_quoted_data

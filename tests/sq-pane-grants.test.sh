#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/sq-pane-grants.sh and the respond-grant hint sq-send.sh
# adds when TUIOS refuses a key, driven through a fake TUIOS CLI (no live
# daemon). The wrapper's authority limits (respond only, one named pane, add
# instead of replace) are asserted from the exact argv the fake records, so a
# refusal is proven to happen before the daemon is asked for anything.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-pane-grants)
FAKE_DIR=$TMP_ROOT/daemon
LOG=$TMP_ROOT/tuios.log
mkdir -p "$TMP_ROOT/fakebin" "$FAKE_DIR" "$TMP_ROOT/base/state"

WRAPPER="$ROOT/bin/sq-pane-grants.sh"
SEND="$ROOT/bin/sq-send.sh"
SESSION=squad
DEFAULT_PANE=aaaaaaaa-1111
RESPOND_PANE=bbbbbbbb-2222
CALLER_PANE=dddddddd-4444
OUTSIDE_SESSION=sq-outside
OUTSIDE_PANE=eeeeeeee-5555
OUTSIDE_PLAIN_PANE=ffffffff-6666

write_windows() {  # <session>
  cat > "$FAKE_DIR/$1.json" <<'JSON'
{"success":true,"windows":[
  {"window_id":"aaaaaaaa-1111","display_name":"π - squad","title":"π - squad"},
  {"window_id":"bbbbbbbb-2222","display_name":"task","grants":["admin","respond"]},
  {"window_id":"cccccccc-3333","display_name":"other","grants":["read","write"]},
  {"window_id":"aaaaaaaa-9999","display_name":"shadow"},
  {"window_id":"99999999-7777","display_name":"blocked-op","agent_state":"needs_input"}
]}
JSON
}

write_caller_pane() {  # <pane-window>
  jq -cn --arg w "$2" --arg s "$1" \
    '{success:true,pane:true,session:$s,window:$w,grants:["admin"],default_grants:["admin"],explicit:false}' \
    > "$FAKE_DIR/pane-grants.json"
}

# The exact payload TUIOS 0.9.1 returns from a shell outside every pane:
# pane:false with the note, and still the daemon's default grants and mode.
write_outside_pane() {
  jq -cn '{success:true,pane:false,mode:"open",default_grants:["admin"],message:"command executed",note:"The caller runs in no pane of this daemon, so no pane grants apply to it."}' \
    > "$FAKE_DIR/pane-grants.json"
}

write_outside_session() {  # <session> <default-pane> <explicitly-granted-pane>
  jq -cn --arg w "$2" --arg e "$3" \
    '{success:true,windows:[{window_id:$w,display_name:"task"},{window_id:$e,display_name:"other",grants:["read"]}]}' \
    > "$FAKE_DIR/$1.json"
}

write_windows "$SESSION"
write_caller_pane "$SESSION" "$CALLER_PANE"

cat > "$TMP_ROOT/fakebin/tuios" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_TUIOS_LOG"
verb=${1:-}
shift || true
session= window= grants=
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift ;;
    --session) session=${2:-}; shift 2 ;;
    --window) window=${2:-}; shift 2 ;;
    --grants) grants=${2:-}; shift 2 ;;
    --json|-*)
      shift
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
case "$verb" in
  list-windows)
    if [ -f "$FAKE_TUIOS_DIR/list-refuse" ]; then
      cat "$FAKE_TUIOS_DIR/list-refuse"
      exit 1
    fi
    if [ -f "$FAKE_TUIOS_DIR/list-malformed" ]; then
      cat "$FAKE_TUIOS_DIR/list-malformed"
      exit 0
    fi
    file=$FAKE_TUIOS_DIR/$session.json
    if [ ! -f "$file" ]; then
      printf '{"error":"session %s not found"}\n' "$session"
      exit 1
    fi
    cat "$file"
    ;;
  get-window)
    id=${positional[0]:-}
    jq -cn --arg w "$id" --arg label "${FAKE_TUIOS_WINDOW_LABEL:-}" \
      '{success:true,id:$w,window_id:$w,name:$label,display_name:$label}'
    ;;
  pane-grants)
    cat "$FAKE_TUIOS_DIR/pane-grants.json"
    ;;
  send-keys)
    if [ -f "$FAKE_TUIOS_DIR/send-keys-refuse" ]; then
      cat "$FAKE_TUIOS_DIR/send-keys-refuse" >&2
      exit 1
    fi
    printf 'sent 1 key to window task\n'
    ;;
  set-pane-grants)
    if [ -f "$FAKE_TUIOS_DIR/set-refuse" ]; then
      cat "$FAKE_TUIOS_DIR/set-refuse"
      exit 1
    fi
    file=$FAKE_TUIOS_DIR/$session.json
    [ -f "$file" ] || {
      printf '{"error":"session %s not found"}\n' "$session"
      exit 1
    }
    printf '%s' "$grants" | jq -R 'split(",")' > "$file.grants"
    jq --arg w "$window" --slurpfile g "$file.grants" \
      '(.windows[] | select(.window_id == $w) | .grants) = $g[0]' "$file" > "$file.tmp" \
      && mv "$file.tmp" "$file"
    printf '{"success":true}\n'
    ;;
  *)
    printf '{"error":"unsupported verb %s"}\n' "$verb"
    exit 1
    ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/tuios"

export PATH="$TMP_ROOT/fakebin:$PATH"
export SQUAD_TUIOS_BIN=tuios
export FAKE_TUIOS_LOG=$LOG
export FAKE_TUIOS_DIR=$FAKE_DIR
export SQUAD_BASE=$TMP_ROOT/base
export SQUAD_STATE_OVERRIDE=$TMP_ROOT/base/state
# The suite runs inside whatever pane invoked it; nothing here may fall back to
# that ambient pane when the fake daemon reports no caller placement.
unset TUIOS_ENV TUIOS_SESSION TUIOS_WINDOW_ID TUIOS_PANE_ID TUIOS_PANE_TOKEN TUIOS_PANE_GRANTS

printf 'backend=tuios\nwindow=%s:%s\nharness=claude\n' "$SESSION" "$DEFAULT_PANE" \
  > "$SQUAD_STATE_OVERRIDE/grantee.meta"
printf 'backend=tmux\nwindow=%s:%s\nharness=claude\n' "$SESSION" "$DEFAULT_PANE" \
  > "$SQUAD_STATE_OVERRIDE/tmux-task.meta"

run_wrapper() {  # <args...>
  local out rc
  out=$("$WRAPPER" "$@" 2>&1)
  rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

reset_log() { : > "$LOG"; }

# --- show ------------------------------------------------------------------

result=$(run_wrapper show "$SESSION:$DEFAULT_PANE")
expect_code 0 "${result%%$'\n'*}" 'show reads a pane that holds the daemon default'
out=${result#*$'\n'}
assert_contains "$out" "target: $SESSION:$DEFAULT_PANE" 'show names the resolved pane'
assert_contains "$out" "grants: admin" 'show reports the daemon default grants'
assert_contains "$out" 'declared: default' 'show says the grants came from the default'
assert_contains "$out" 'respond: absent' 'show reports the missing respond grant'
assert_contains "$out" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $SESSION:$DEFAULT_PANE" \
  'show prints the copy-paste person command with the resolved window id'

result=$(run_wrapper show "$SESSION:$RESPOND_PANE")
expect_code 0 "${result%%$'\n'*}" 'show reads an explicit grant set'
out=${result#*$'\n'}
assert_contains "$out" 'grants: admin,respond' 'show reports the explicit grants'
assert_contains "$out" 'declared: explicit' 'show says the grants are explicit'
assert_contains "$out" 'respond: present' 'show reports respond as present'
assert_not_contains "$out" 'person command:' 'a granted pane needs no person command'

# show with no target reports the pane the command runs in.
result=$(run_wrapper show)
expect_code 0 "${result%%$'\n'*}" 'show without a target reads the calling pane'
assert_contains "$result" "target: $SESSION:$CALLER_PANE" 'show names the calling pane from the daemon placement'
assert_contains "$result" 'respond: absent' 'show reports the calling pane without respond'
assert_contains "$result" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $SESSION:$CALLER_PANE" \
  'show prints the person command for the calling pane'

# A pane the daemon reports without both fields never yields a partial command.
printf '%s\n' '{"success":true,"pane":true,"session":"squad","grants":["admin"],"default_grants":["admin"],"explicit":false}' \
  > "$FAKE_DIR/pane-grants.json"
result=$(run_wrapper show)
expect_code 0 "${result%%$'\n'*}" 'show still reads grants when the payload has no window'
assert_contains "$result" 'target: unreadable' 'a payload without a window is reported as unreadable'
assert_not_contains "$result" 'person command:' 'an unreadable target never yields a person command'
write_caller_pane "$SESSION" "$CALLER_PANE"

# show outside every pane: the recorded pane:false payload has no pane to read,
# so the command must finish instead of aborting on a placement it cannot name.
write_outside_pane
result=$(run_wrapper show)
expect_code 0 "${result%%$'\n'*}" 'show reports a caller in no pane instead of aborting'
out=${result#*$'\n'}
assert_contains "$out" 'target: none' 'show says the caller runs in no pane of the daemon'
assert_not_contains "$out" 'grants:' 'the daemon default is never reported as a pane this caller runs in'
assert_contains "$out" "$ROOT/bin/sq-pane-grants.sh show <session>:<window>" \
  'an outside-pane caller is told how to name a pane instead'
assert_not_contains "$out" 'person command:' 'a caller in no pane has no window to name in a person command'

# A pane-grants payload that reported failure or is not JSON is never reported
# as "this command runs in no pane": the read fails closed like every other read.
printf '{"success":false,"error":"daemon is busy"}\n' > "$FAKE_DIR/pane-grants.json"
result=$(run_wrapper show)
expect_code 1 "${result%%$'\n'*}" 'show refuses a pane-grants payload that reports failure'
out=${result#*$'\n'}
assert_contains "$out" 'pane-grants payload is unreadable' 'a failed payload is reported as unreadable'
assert_not_contains "$out" 'target: none' 'a failed payload is never reported as a caller in no pane'

printf 'not json at all\n' > "$FAKE_DIR/pane-grants.json"
result=$(run_wrapper show)
expect_code 1 "${result%%$'\n'*}" 'show refuses a pane-grants payload that is not JSON'
assert_contains "$result" 'unreadable' 'a malformed payload is reported as unreadable'
assert_not_contains "$result" 'target: none' 'a malformed payload is never reported as a caller in no pane'

# A pane whose grants are the daemon default cannot be read without that
# default, and the refusal says so instead of writing a guessed grant list.
printf '%s\n' '{"success":true,"pane":true,"session":"squad","window":"dddddddd-4444","mode":"open"}' \
  > "$FAKE_DIR/pane-grants.json"
result=$(run_wrapper show)
expect_code 1 "${result%%$'\n'*}" 'show refuses a pane whose default grants the daemon does not report'
assert_contains "$result" 'no default_grants field (mode=open)' \
  'the refusal names the missing defaults and the daemon mode'
assert_contains "$result" 'refusing to guess or replace them' 'the refusal states that nothing was written'

# An explicitly empty default is a real answer, not a missing field: the pane
# holds nothing, so the add-only write must produce respond alone.
printf '%s\n' '{"success":true,"pane":true,"session":"squad","window":"dddddddd-4444","mode":"strict","default_grants":"admin","grants":[],"explicit":true}' \
  > "$FAKE_DIR/pane-grants.json"
result=$(run_wrapper show)
expect_code 1 "${result%%$'\n'*}" 'show refuses a default_grants value that is not a list'
assert_contains "$result" 'unreadable shape' 'a non-list default is refused instead of read as empty'

printf '%s\n' '{"success":true,"pane":true,"session":"squad","window":"dddddddd-4444","mode":"strict","default_grants":[],"grants":[],"explicit":true}' \
  > "$FAKE_DIR/pane-grants.json"
result=$(run_wrapper show)
expect_code 0 "${result%%$'\n'*}" 'show accepts an explicitly empty grant set'
assert_contains "$result" 'grants: none' 'an empty grant set is reported as none'
assert_contains "$result" 'person command:' 'an empty grant set still yields the person command'
write_caller_pane "$SESSION" "$CALLER_PANE"

# An inventory record with an explicitly empty grants list is explicit, not the
# daemon default, so the add-only write never turns a deliberate grant removal
# into admin,respond.
write_empty_grant_session() {
  jq -cn '{success:true,windows:[{window_id:"eeeeeeee-5555",display_name:"empty",grants:[]}]}' \
    > "$FAKE_DIR/emptygrants.json"
}
write_empty_grant_session
result=$(run_wrapper show "emptygrants:eeeeeeee-5555")
expect_code 0 "${result%%$'\n'*}" 'show reads a pane with an explicitly empty grant list'
assert_contains "$result" 'declared: explicit' 'an empty grant list counts as explicit'
assert_contains "$result" 'grants: none' 'an empty grant list is reported as none'
result=$(run_wrapper verify "emptygrants:eeeeeeee-5555")
expect_code 1 "${result%%$'\n'*}" 'verify fails for a pane that deliberately holds nothing'
assert_contains "$result" '(holds none)' 'verify says a pane with no grants holds none'
reset_log
result=$(run_wrapper grant respond "emptygrants:eeeeeeee-5555")
expect_code 0 "${result%%$'\n'*}" 'grant adds respond to a pane that deliberately holds nothing'
assert_grep 'set-pane-grants --session emptygrants --window eeeeeeee-5555 --grants respond' "$LOG" \
  'the add-only write preserves an empty grant set instead of restoring a default'

# The headline path: a shell outside every pane is the only caller TUIOS accepts
# for the first grant, so show, grant, and verify are driven from exactly that
# placement against the recorded outside-pane payload.
write_outside_session "$OUTSIDE_SESSION" "$OUTSIDE_PANE" "$OUTSIDE_PLAIN_PANE"
write_outside_pane
result=$(run_wrapper show "$OUTSIDE_SESSION:$OUTSIDE_PANE")
expect_code 0 "${result%%$'\n'*}" 'show reads a default-granted pane from outside every pane'
out=${result#*$'\n'}
assert_contains "$out" "target: $OUTSIDE_SESSION:$OUTSIDE_PANE" 'show names the resolved pane from outside'
assert_contains "$out" 'grants: admin' 'show reads the inherited daemon default from outside every pane'
assert_contains "$out" 'respond: absent' 'show reports the missing respond grant from outside'
assert_contains "$out" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $OUTSIDE_SESSION:$OUTSIDE_PANE" \
  'the person command printed from outside names the resolved pane'

reset_log
result=$(run_wrapper grant respond "$OUTSIDE_SESSION:$OUTSIDE_PANE")
expect_code 0 "${result%%$'\n'*}" 'the printed person command works from outside every pane'
assert_contains "${result#*$'\n'}" 'granted: respond' 'the outside-pane grant reports the added grant'
assert_grep "set-pane-grants --session $OUTSIDE_SESSION --window $OUTSIDE_PANE --grants admin,respond" "$LOG" \
  'the grant keeps the inherited default and adds only respond'

result=$(run_wrapper verify "$OUTSIDE_SESSION:$OUTSIDE_PANE")
expect_code 0 "${result%%$'\n'*}" 'verify confirms the grant from outside every pane'
assert_contains "$result" 'verified' 'verify reports the grant landed'

result=$(run_wrapper verify "$OUTSIDE_SESSION:$OUTSIDE_PLAIN_PANE")
expect_code 1 "${result%%$'\n'*}" 'verify fails for a pane without respond from outside'
assert_contains "$result" 'does not hold respond' 'the failing verify names the missing grant'
assert_contains "$result" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $OUTSIDE_SESSION:$OUTSIDE_PLAIN_PANE" \
  'the failing verify prints the person command for that pane'

reset_log
write_caller_pane "$SESSION" "$CALLER_PANE"

result=$(run_wrapper show grantee)
expect_code 0 "${result%%$'\n'*}" 'show resolves a task id through its meta record'
assert_contains "${result#*$'\n'}" "target: $SESSION:$DEFAULT_PANE" 'show reports the task meta window'

result=$(run_wrapper show sq-grantee)
expect_code 0 "${result%%$'\n'*}" 'show accepts the legacy sq- task label'

result=$(run_wrapper show "$SESSION:bbbb")
expect_code 0 "${result%%$'\n'*}" 'show accepts a unique window id prefix'
assert_contains "${result#*$'\n'}" "target: $SESSION:$RESPOND_PANE" 'show canonicalizes the prefix to the exact id'

result=$(run_wrapper show tmux-task)
expect_code 1 "${result%%$'\n'*}" 'show refuses a task on another backend'
assert_contains "$result" 'records backend=tmux' 'the refusal names the recorded backend'

result=$(run_wrapper show nosuch-task)
expect_code 1 "${result%%$'\n'*}" 'show refuses an unknown task id'
assert_contains "$result" 'unknown target' 'the unknown task refusal is actionable'

result=$(run_wrapper show "$SESSION:nosuchwindow")
expect_code 1 "${result%%$'\n'*}" 'show refuses an unknown window'
assert_contains "$result" 'no unambiguous window' 'the unknown window refusal is actionable'
assert_contains "$result" "$DEFAULT_PANE" 'the unknown window refusal lists the real windows'

result=$(run_wrapper show "$SESSION:aa")
expect_code 1 "${result%%$'\n'*}" 'show refuses an ambiguous window prefix'

printf 'list-windows failed: the daemon is not answering\n' > "$FAKE_DIR/list-refuse"
result=$(run_wrapper show "$SESSION:$DEFAULT_PANE")
expect_code 1 "${result%%$'\n'*}" 'show refuses an unreadable inventory'
assert_contains "$result" 'cannot read the TUIOS window inventory' 'the unreadable inventory refusal is actionable'
rm -f "$FAKE_DIR/list-refuse"

printf '{"success":true,"windows":"nope"}\n' > "$FAKE_DIR/list-malformed"
result=$(run_wrapper show "$SESSION:$DEFAULT_PANE")
expect_code 1 "${result%%$'\n'*}" 'show refuses a malformed inventory'
assert_contains "$result" 'unreadable' 'the malformed inventory refusal is actionable'
rm -f "$FAKE_DIR/list-malformed"

# --- grant -----------------------------------------------------------------

reset_log
result=$(run_wrapper grant respond "$SESSION:$DEFAULT_PANE")
expect_code 0 "${result%%$'\n'*}" 'grant respond adds the respond grant to a default pane'
assert_contains "${result#*$'\n'}" 'granted: respond' 'grant reports the added grant'
assert_grep "set-pane-grants --session $SESSION --window $DEFAULT_PANE --grants admin,respond" "$LOG" \
  'grant keeps what the pane held and adds only respond'
assert_contains "$("$WRAPPER" show "$SESSION:$DEFAULT_PANE")" 'respond: present' \
  'the granted pane now reads back respond'

reset_log
result=$(run_wrapper grant respond "$SESSION:$DEFAULT_PANE")
expect_code 0 "${result%%$'\n'*}" 'grant respond is idempotent'
assert_contains "$result" 'already granted' 'the idempotent path says nothing changed'
assert_no_grep 'set-pane-grants' "$LOG" 'the idempotent path never calls the daemon'

for refused in admin read write fan none admin,respond 'respond,admin'; do
  reset_log
  result=$(run_wrapper grant "$refused" "$SESSION:$DEFAULT_PANE")
  expect_code 2 "${result%%$'\n'*}" "grant $refused is refused as a request shape"
  assert_contains "$result" 'only the respond grant can be added' "the $refused refusal explains the limit"
  assert_no_grep 'set-pane-grants' "$LOG" "the $refused refusal never reaches the daemon"
done

reset_log
result=$(run_wrapper grant respond)
expect_code 2 "${result%%$'\n'*}" 'grant without a target is refused'
assert_no_grep 'set-pane-grants' "$LOG" 'a targetless grant never reaches the daemon'

result=$(run_wrapper grant respond "$SESSION:$DEFAULT_PANE" "$SESSION:$RESPOND_PANE")
expect_code 2 "${result%%$'\n'*}" 'grant refuses more than one target'

result=$(run_wrapper grant respond "$SESSION")
expect_code 1 "${result%%$'\n'*}" 'grant refuses a bare session target'
assert_contains "$result" 'never a bare session' 'the bare session refusal says what to pass instead'

result=$(run_wrapper show "$SESSION:$DEFAULT_PANE" extra)
expect_code 2 "${result%%$'\n'*}" 'show refuses a second target'

result=$(run_wrapper frobnicate)
expect_code 2 "${result%%$'\n'*}" 'an unknown subcommand is refused'

printf 'set-pane-grants failed: set-pane-grants is refused for this pane: a pane cannot give more than it holds.\n' \
  > "$FAKE_DIR/set-refuse"
result=$(run_wrapper grant respond "$SESSION:cccccccc-3333")
expect_code 1 "${result%%$'\n'*}" 'a daemon refusal fails the grant'
assert_contains "$result" 'a pane cannot give more than it holds' 'the daemon refusal is reported verbatim'
assert_contains "$result" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $SESSION:cccccccc-3333" \
  'the daemon refusal prints the same copy-paste person command'
rm -f "$FAKE_DIR/set-refuse"

# --- verify ----------------------------------------------------------------

result=$(run_wrapper verify "$SESSION:$RESPOND_PANE")
expect_code 0 "${result%%$'\n'*}" 'verify passes for a pane that holds respond'
assert_contains "$result" "verified: $SESSION:$RESPOND_PANE holds respond" 'verify names the confirmed pane'

result=$(run_wrapper verify "$SESSION:cccccccc-3333")
expect_code 1 "${result%%$'\n'*}" 'verify fails while respond is still absent'
assert_contains "$result" "absent: $SESSION:cccccccc-3333 does not hold respond" 'verify names the pane that still needs the grant'
assert_contains "$result" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $SESSION:cccccccc-3333" \
  'verify prints the copy-paste person command instead of guessing'

reset_log
result=$(run_wrapper verify "$SESSION:cccccccc-3333")
assert_no_grep 'set-pane-grants' "$LOG" 'verify never changes anything'

# The delegation lands: verify then agrees, and the supervisor's retry is safe.
result=$(run_wrapper grant respond "$SESSION:cccccccc-3333")
expect_code 0 "${result%%$'\n'*}" 'grant succeeds for the pane verify reported absent'
result=$(run_wrapper verify "$SESSION:cccccccc-3333")
expect_code 0 "${result%%$'\n'*}" 'verify confirms the grant landed'
assert_contains "$result" 'holds respond' 'verify reports the landed grant'

result=$(run_wrapper verify grantee)
expect_code 0 "${result%%$'\n'*}" 'verify resolves a task id and agrees with the earlier grant'
assert_contains "$result" "verified: $SESSION:$DEFAULT_PANE holds respond" 'verify reports the task pane by its exact id'

# The pane that waits on a prompt is never offered the grant: TUIOS needs it on
# the pane that types the answer, and granting this one changes nothing.
result=$(run_wrapper show "$SESSION:99999999-7777")
expect_code 0 "${result%%$'\n'*}" 'show still reads the pane that waits on a prompt'
assert_contains "$result" 'is the pane waiting on a prompt' 'show explains why that pane is the wrong target'
assert_not_contains "$result" 'person command:' 'show offers no person command for the blocked pane'

reset_log
result=$(run_wrapper grant respond "$SESSION:99999999-7777")
expect_code 1 "${result%%$'\n'*}" 'grant refuses the pane that waits on a prompt'
assert_contains "$result" 'respond must go on the pane that types the answer' 'the refusal says where the grant belongs'
assert_no_grep 'set-pane-grants' "$LOG" 'the refused blocked-pane grant never reaches the daemon'

result=$(run_wrapper verify "$SESSION:99999999-7777")
expect_code 1 "${result%%$'\n'*}" 'verify stays non-zero for the blocked pane'
assert_not_contains "$result" 'person command:' 'verify offers no person command for the blocked pane'

result=$(run_wrapper verify)
expect_code 2 "${result%%$'\n'*}" 'verify without a target is refused'
result=$(run_wrapper verify "$SESSION:$DEFAULT_PANE" "$SESSION:$RESPOND_PANE")
expect_code 2 "${result%%$'\n'*}" 'verify refuses more than one target'
result=$(run_wrapper verify "$SESSION:nosuchwindow")
expect_code 1 "${result%%$'\n'*}" 'verify refuses an unknown window'

# --- sq-send names the wrapper instead of the raw CLI advice ---------------

printf 'backend=tuios\nwindow=%s:%s\nharness=claude\n' "$SESSION" "$DEFAULT_PANE" \
  > "$SQUAD_STATE_OVERRIDE/grantee.meta"
cat > "$FAKE_DIR/send-keys-refuse" <<'TXT'
send-keys failed: send-keys is refused for this pane: window aaaaaaaa is waiting on a prompt, and what is typed now would answer it, which needs the respond grant.
Most likely cause: Pane dddddddd holds admin, the default of [agents.permissions]. Nothing was done. The person can give this pane more with tuios set-pane-grants -w dddddddd --grants <names>.
TXT
reset_log
send_out=$(FAKE_TUIOS_WINDOW_LABEL=sq-grantee "$SEND" grantee --key Enter 2>&1)
send_rc=$?
expect_code 1 "$send_rc" 'sq-send reports the refused key'
assert_contains "$send_out" 'not sent to' 'sq-send keeps its own failure line'
assert_contains "$send_out" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $SESSION:$CALLER_PANE" \
  'sq-send prints the same copy-paste person command show and verify print'
assert_contains "$send_out" 'needs the respond grant' 'sq-send keeps the provider refusal sentence as evidence'
assert_not_contains "$send_out" 'The person can give this pane more with' \
  'sq-send drops the provider remediation advice that names the refused raw verb'
rm -f "$FAKE_DIR/send-keys-refuse"

# A caller whose placement the daemon cannot report falls back to the pane id
# Squad uses everywhere else, so the person command survives that degradation.
write_outside_pane
printf 'backend=tuios\nwindow=%s:%s\nharness=claude\n' "$SESSION" "$DEFAULT_PANE" \
  > "$SQUAD_STATE_OVERRIDE/grantee.meta"
printf '%s\n' 'send-keys failed: send-keys is refused for this pane: window aaaaaaaa is waiting on a prompt, and what is typed now would answer it, which needs the respond grant.' \
  > "$FAKE_DIR/send-keys-refuse"
send_out=$(TUIOS_SESSION="$SESSION" TUIOS_PANE_ID="$CALLER_PANE" FAKE_TUIOS_WINDOW_LABEL=sq-grantee \
  "$SEND" grantee --key Enter 2>&1)
expect_code 1 "$?" 'sq-send still reports the refused key for an unplaced caller'
assert_contains "$send_out" "person command: $ROOT/bin/sq-pane-grants.sh grant respond $SESSION:$CALLER_PANE" \
  'the pane-id fallback still names the pane that must hold respond'
rm -f "$FAKE_DIR/send-keys-refuse"
write_caller_pane "$SESSION" "$CALLER_PANE"

# A caller pane the daemon reports without both fields yields no partial command.
printf '%s\n' '{"success":true,"pane":true,"session":"squad","grants":["admin"],"default_grants":["admin"]}' \
  > "$FAKE_DIR/pane-grants.json"
printf '%s\n' 'send-keys failed: send-keys is refused for this pane: window aaaaaaaa is waiting on a prompt, and what is typed now would answer it, which needs the respond grant.' \
  > "$FAKE_DIR/send-keys-refuse"
send_out=$(FAKE_TUIOS_WINDOW_LABEL=sq-grantee "$SEND" grantee --key Enter 2>&1)
send_rc=$?
expect_code 1 "$send_rc" 'sq-send still reports the refused key without a caller pane'
assert_contains "$send_out" 'needs the respond grant' 'the provider refusal sentence is still reported'
assert_not_contains "$send_out" 'person command:' 'an unnamed caller pane never yields a partial person command'
rm -f "$FAKE_DIR/send-keys-refuse"
write_caller_pane "$SESSION" "$CALLER_PANE"

pass 'pane grants: respond-only wrapper refusals, the copy-paste person command, the verify gate, and the sq-send remedy hint'

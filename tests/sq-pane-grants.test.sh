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

write_windows() {  # <session>
  cat > "$FAKE_DIR/$1.json" <<'JSON'
{"success":true,"windows":[
  {"window_id":"aaaaaaaa-1111","display_name":"π - squad","title":"π - squad"},
  {"window_id":"bbbbbbbb-2222","display_name":"task","grants":["admin","respond"]},
  {"window_id":"cccccccc-3333","display_name":"other","grants":["read","write"]},
  {"window_id":"aaaaaaaa-9999","display_name":"shadow"}
]}
JSON
}

write_caller_pane() {  # <pane-window>
  jq -cn --arg w "$2" --arg s "$1" \
    '{success:true,pane:true,session:$s,window:$w,grants:["admin"],default_grants:["admin"],explicit:false}' \
    > "$FAKE_DIR/pane-grants.json"
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

result=$(run_wrapper show "$SESSION:$RESPOND_PANE")
expect_code 0 "${result%%$'\n'*}" 'show reads an explicit grant set'
out=${result#*$'\n'}
assert_contains "$out" 'grants: admin,respond' 'show reports the explicit grants'
assert_contains "$out" 'declared: explicit' 'show says the grants are explicit'
assert_contains "$out" 'respond: present' 'show reports respond as present'

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
assert_contains "$result" "bin/sq-pane-grants.sh grant respond $SESSION:cccccccc-3333" \
  'the daemon refusal names the exact outside-pane command'
rm -f "$FAKE_DIR/set-refuse"

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
assert_contains "$send_out" "bin/sq-pane-grants.sh grant respond $SESSION:$CALLER_PANE" \
  'sq-send names the wrapper and the pane whose grant is missing'
assert_contains "$send_out" 'needs the respond grant' 'sq-send keeps the daemon refusal as evidence'
rm -f "$FAKE_DIR/send-keys-refuse"

pass 'pane grants: respond-only wrapper refusals, grant verification, and the sq-send remedy hint'

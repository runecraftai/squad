#!/usr/bin/env bash
# Fake-CLI regression coverage for the explicit TUIOS session-provider adapter.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot sq-backend-tuios-tests)
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/tuios" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$SQUAD_TUIOS_LOG"
emit_verb_catalogue() {
  cat <<'JSON'
{"version":1,"daemon_version":"0.8.0","success":true,"verbs":[
 {"verb":"capture-pane","params":[{"name":"session"},{"name":"window"},{"name":"scrollback"},{"name":"lines"}]},
 {"verb":"close-window","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"get-agent-state","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"get-window","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"list-agents","params":[{"name":"session"},{"name":"all"},{"name":"select"}]},
 {"verb":"list-queued","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"list-windows","params":[{"name":"session"}]},
 {"verb":"list-workspaces","params":[{"name":"session"}]},
 {"verb":"new-window","params":[{"name":"session"},{"name":"name"},{"name":"cwd"},{"name":"focus"},{"name":"workspace"}]},
 {"verb":"set-workspace-name","params":[{"name":"session"},{"name":"workspace"},{"name":"name"}]},
 {"verb":"peek-prompt","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"queue-prompt","params":[{"name":"session"},{"name":"window"},{"name":"text"},{"name":"from"}]},
 {"verb":"resume-agent","params":[{"name":"session"},{"name":"window"},{"name":"dry_run"}]},
 {"verb":"send-keys","params":[{"name":"session"},{"name":"window"},{"name":"keys"}]},
 {"verb":"send-text","params":[{"name":"session"},{"name":"window"},{"name":"text"}]}
]}
JSON
}
case "${1:-}" in
  --version) printf 'tuios version %s\n' "${SQUAD_TUIOS_FAKE_VERSION:-0.8.0}" ;;
  session-info)
    [ "${SQUAD_TUIOS_FAKE_SESSION_DEAD:-0}" = 1 ] && exit 1
    printf '{"name":"%s"}\n' "${SQUAD_TUIOS_FAKE_SESSION:-owned}"
    ;;
  list-verbs)
    if [ "${SQUAD_TUIOS_FAKE_VERBS_FAIL:-0}" = 1 ]; then exit 1; fi
    if [ -n "${SQUAD_TUIOS_FAKE_VERBS_MALFORMED:-}" ]; then printf '%s\n' "$SQUAD_TUIOS_FAKE_VERBS_MALFORMED"; exit 0; fi
    emit_verb_catalogue | jq -c --arg verb "${SQUAD_TUIOS_FAKE_VERBS_OMIT:-}" --arg pair "${SQUAD_TUIOS_FAKE_PARAM_OMIT:-}" '
      if $verb != "" then .verbs |= map(select(.verb != $verb)) else . end
      | if $pair != "" then
          ($pair | split(":")) as $p
          | .verbs |= map(if .verb == $p[0] then .params |= map(select(.name != $p[1])) else . end)
        else . end'
    ;;
  list-attention)
    printf '{"boot_id":"%s","success":true,"items":[]}\n' "${SQUAD_TUIOS_FAKE_BOOT_ID:-boot-a}"
    ;;
  list-workspaces)
    [ "${SQUAD_TUIOS_FAKE_WORKSPACES_FAIL:-0}" = 1 ] && exit 1
    if [ "${SQUAD_TUIOS_FAKE_ALLOC_PAUSE:-0}" = 1 ] && [ ! -e "$SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK" ]; then
      : > "$SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK"
      for _ in $(seq 1 500); do
        [ ! -e "$SQUAD_TUIOS_FAKE_ALLOC_RELEASE" ] || break
        sleep 0.01
      done
      [ -e "$SQUAD_TUIOS_FAKE_ALLOC_RELEASE" ] || exit 80
    fi
    rows=()
    for workspace in $(seq 1 9); do
      name= count=0
      case "$workspace" in 1) name=personal; count=1 ;; 4) name=existing; count=1 ;; esac
      if [ -f "$SQUAD_TUIOS_CREATED_WORKSPACE" ] && [ "$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE")" = "$workspace" ]; then
        name=$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME" 2>/dev/null || printf '')
        [ ! -f "$SQUAD_TUIOS_CREATED_WINDOW" ] || count=1
      fi
      rows+=("$(jq -cn --argjson ws "$workspace" --arg name "$name" --argjson count "$count" '{workspace:$ws,name:$name,window_count:$count}')")
    done
    printf '{"success":true,"workspaces":[%s]}\n' "$(IFS=,; echo "${rows[*]}")"
    ;;
  set-workspace-name)
    shift
    [ "${1:-}" = --session ] && shift 2
    printf '%s\n' "${1:-}" > "$SQUAD_TUIOS_CREATED_WORKSPACE"
    printf '%s\n' "${2:-}" > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
    printf '{"success":true}\n'
    ;;
  list-windows)
    if [ "${SQUAD_TUIOS_FAKE_LIST_FAIL:-0}" = 1 ]; then
      exit 1
    elif [ "${SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE:-0}" = 1 ] && [ -f "$SQUAD_TUIOS_CREATED_WINDOW" ]; then
      exit 1
    elif [ "${SQUAD_TUIOS_FAKE_BAD_ELEMENT:-0}" = 1 ]; then
      printf '{"windows":["x"]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE:-0}" = 1 ]; then
      printf '{"windows":[{"window_id":"w-opaque_7","name":"sq-task-1","workspace":%s,"cwd":"/tmp/wt"}]}\n' "${SQUAD_TUIOS_FAKE_PLACEMENT:-4}"
    elif [ "${SQUAD_TUIOS_FAKE_NO_IDENTITY:-0}" = 1 ]; then
      printf '{"windows":[{"name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_CONFLICTING_ID:-0}" = 1 ]; then
      printf '{"windows":[{"window":{"id":"w-opaque_7"},"id":"stale-id","name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_NESTED_LABEL:-0}" = 1 ]; then
      printf '{"windows":[{"id":"w-opaque_7","window":{"id":"w-opaque_7","name":"sq-nested"},"cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_NESTED_WORKSPACE:-0}" = 1 ]; then
      printf '{"windows":[{"window":{"id":"w-opaque_7","workspace":%s}}]}\n' "${SQUAD_TUIOS_FAKE_PLACEMENT:-$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE" 2>/dev/null || printf '2')}"
    elif [ "${SQUAD_TUIOS_FAKE_NO_WORKSPACE:-0}" = 1 ]; then
      # Pre-creation empty so label conflict does not trip; post-creation a
      # record that omits every workspace field, i.e. missing placement.
      if [ ! -f "$SQUAD_TUIOS_CREATED_WINDOW" ]; then
        printf '{"windows":[]}\n'
      else
        printf '{"windows":[{"id":"w-opaque_7","name":"%s","cwd":"/tmp/wt"}]}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}"
      fi
    elif [ "${SQUAD_TUIOS_FAKE_DURABLE_LABEL:-0}" = 1 ]; then
      printf '{"windows":[{"id":"w-opaque_7","custom_name":"sq-durable","title":"pi - live","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ERROR_INVENTORY:-0}" = 1 ]; then
      printf '{"error":{"code":"daemon_unreachable"}}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS:-0}" = 1 ]; then
      printf '{"error":{"code":"daemon_unreachable"},"windows":[]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_STRING_WINDOW:-0}" = 1 ]; then
      printf '{"windows":[{"window":"w-opaque_7","name":"sq-task-1","workspace":4}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_MISSING:-0}" = 1 ] || { [ "${SQUAD_TUIOS_FAKE_EMPTY_WINDOWS:-0}" = 1 ] && [ ! -f "$SQUAD_TUIOS_CREATED_WINDOW" ]; }; then
      printf '{"windows":[]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_RESTORED_WINDOW:-0}" = 1 ]; then
      printf '{"windows":[{"window_id":"w-opaque_7","custom_name":"sq-task-1","workspace":4,"cwd":"%s"}]}\n' "${SQUAD_TUIOS_FAKE_RESTORED_CWD:-/tmp/wt}"
    else
      name=${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}
      [ ! -f "$SQUAD_TUIOS_CREATED_LABEL" ] || name=$(<"$SQUAD_TUIOS_CREATED_LABEL")
      placement=${SQUAD_TUIOS_FAKE_PLACEMENT:-$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE" 2>/dev/null || printf '5')}
      printf '{"windows":[{"id":"w-opaque_7","name":"%s","workspace":%s,"cwd":"/tmp/wt"}]}\n' "$name" "$placement"
    fi
    ;;
  get-window)
    if [ "${SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE:-0}" = 1 ]; then
      marker="$SQUAD_TUIOS_CREATED_WINDOW.get-window-failed"
      if [ ! -f "$marker" ]; then
        touch "$marker"
        exit 1
      fi
    fi
    # A session with an attached client omits the daemon cwd from this shape;
    # list-windows is the shape that always carries it.
    if [ "${SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW:-0}" = 1 ]; then
      printf '{"error":{"code":"window_gone"},"window":{"id":"w-opaque_7","name":"sq-task-1"}}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ATTACHED_CLIENT:-0}" = 1 ]; then
      printf '{"window":{"id":"w-opaque_7","name":"%s","has_foreground_process":true}}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}"
    else
      printf '{"window":{"id":"w-opaque_7","name":"%s","cwd":"/tmp/wt","has_foreground_process":false}}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}"
    fi
    ;;
  list-agents)
    if [ -n "${SQUAD_TUIOS_FAKE_AGENTS:-}" ]; then printf '%s\n' "$SQUAD_TUIOS_FAKE_AGENTS"; else
      printf '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done"}]}\n'
    fi
    ;;
  get-agent-state)
    printf '{"state":"%s","blocked_by":"%s","needs_you":%s,"ready":%s,"success":true}\n' \
      "${SQUAD_TUIOS_FAKE_AGENT_STATE:-working}" \
      "${SQUAD_TUIOS_FAKE_BLOCKED_BY:-}" \
      "${SQUAD_TUIOS_FAKE_NEEDS_YOU:-false}" \
      "${SQUAD_TUIOS_FAKE_READY:-false}"
    ;;
  peek-prompt)
    if [ "${SQUAD_TUIOS_FAKE_PROMPT_STATE:-blocked}" = unblocked ]; then
      printf '{"blocked":false,"found":false,"reason":"the pane is not on needs_input","success":true}\n'
    else
      printf '{"blocked":true,"found":%s,"kind":"%s","message":"%s","lines":["%s"],"options":[],"prompt_id":"p1","answerable":false,"reason":"%s","success":true}\n' \
        "${SQUAD_TUIOS_FAKE_PROMPT_FOUND:-true}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_KIND:-approval}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_MESSAGE:-approve Bash: make}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_MESSAGE:-approve Bash: make}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_REASON:-}"
    fi
    ;;
  queue)
    if [ "${2:-}" = ls ]; then
      if [ -n "${SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ:-}" ]; then
        seq_file=${SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE:?}
        n=$(cat "$seq_file" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" > "$seq_file"
        state=$(printf '%s' "$SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ" | cut -d, -f"$n")
        [ -n "$state" ] || state=$(printf '%s' "$SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ" | awk -F, '{print $NF}')
        printf '{"entries":[{"id":"%s","state":"%s"}]}\n' "${SQUAD_TUIOS_FAKE_QUEUE_ID:-q1}" "$state"
        exit 0
      fi
      if [ -n "${SQUAD_TUIOS_FAKE_QUEUE_LS:-}" ]; then
        printf '%s\n' "$SQUAD_TUIOS_FAKE_QUEUE_LS"
      else
        printf '{"entries":[]}\n'
      fi
      exit 0
    fi
    if [ "${SQUAD_TUIOS_FAKE_QUEUE_FAIL:-0}" = 1 ]; then
      printf '%s' "${SQUAD_TUIOS_FAKE_QUEUE_ERROR:-queue-prompt failed}" | jq -Rs '{error: ., success: false}'
      exit 1
    fi
    printf '{"delivering":%s,"id":"%s","position":1,"queued":1,"success":true}\n' \
      "${SQUAD_TUIOS_FAKE_QUEUE_DELIVERING:-false}" "${SQUAD_TUIOS_FAKE_QUEUE_ID:-q1}"
    ;;
  resume-agent)
    if [ "${SQUAD_TUIOS_FAKE_RESUME_OK:-0}" = 1 ]; then
      printf '{"agent_session_id":"sid","command":"claude --resume sid","success":true,"typed":true,"window_id":"w-opaque_7"}\n'
    else
      printf '{"error":"%s","success":false}\n' "${SQUAD_TUIOS_FAKE_RESUME_ERROR:-resume-agent failed}"
      exit 1
    fi
    ;;
  run-command)
    # `run-command CloseWindow <id> --json`: exits 0 even when the close failed,
    # so the envelope is the only success signal.
    if [ "${SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE:-}" = fail ]; then
      printf '{"message":"%s","success":false}\n' "${SQUAD_TUIOS_FAKE_CLOSE_MESSAGE:-no window found matching w-opaque_7}"
    else
      [ "${4:-}" != CloseWindow ] || rm -f "$SQUAD_TUIOS_CREATED_WINDOW"
      printf '{"message":"command executed","success":true}\n'
    fi
    ;;
  capture-pane) printf '%s\n' "${SQUAD_TUIOS_FAKE_CAPTURE:-captured output}" ;;
  new-window)
    printf '%s\n' "${2:-sq-task-1}" > "$SQUAD_TUIOS_CREATED_LABEL"
    shift 2
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --workspace ]; then printf '%s\n' "$2" > "$SQUAD_TUIOS_CREATED_WORKSPACE"; shift 2; else shift; fi
    done
    touch "$SQUAD_TUIOS_CREATED_WINDOW"
    printf 'w-opaque_7\n'
    ;;
  *) : ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/tuios"
export PATH="$TMP_ROOT/fakebin:$PATH" SQUAD_TUIOS_BIN=tuios SQUAD_TUIOS_LOG="$TMP_ROOT/log" \
  SQUAD_TUIOS_CREATED_WINDOW="$TMP_ROOT/created-window" SQUAD_TUIOS_CREATED_LABEL="$TMP_ROOT/created-label" \
  SQUAD_TUIOS_CREATED_WORKSPACE="$TMP_ROOT/created-workspace" \
  SQUAD_TUIOS_CREATED_WORKSPACE_NAME="$TMP_ROOT/created-workspace-name" \
  SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/config" SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/state"
mkdir -p "$TMP_ROOT/config" "$TMP_ROOT/state" "$TMP_ROOT/runtime"
XDG_RUNTIME_DIR="$TMP_ROOT/runtime"
export XDG_RUNTIME_DIR

source "$ROOT/bin/sq-backend.sh"
SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/config"
SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/state"
export SQUAD_BACKEND_CONFIG_DIR SQUAD_BACKEND_STATE_DIR
fm_backend_validate_spawn tuios || fail 'TUIOS should be a supported spawn backend'
[ "$(fm_backend_required_tools tuios)" = 'tuios jq fob flock' ] || fail 'required tools mismatch'
fm_backend_source tuios || fail 'adapter did not source'
fm_backend_tuios_tool_check || fail 'minimum TUIOS version should pass'

[ "$(fm_backend_tuios_target_exists owned:w-opaque_7 sq-task-1 && echo yes)" = yes ] || fail 'exact opaque target should resolve'
[ "$(fm_backend_tuios_capture owned:w-opaque_7 10 sq-task-1)" = 'captured output' ] || fail 'capture failed'

# Protocol discovery: the daemon's own verb catalogue must carry every verb and
# parameter this adapter uses before any task is created.
fm_backend_tuios_protocol_check owned || fail 'a complete verb catalogue must pass protocol discovery'
SQUAD_TUIOS_FAKE_VERBS_OMIT=resume-agent
export SQUAD_TUIOS_FAKE_VERBS_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-verb-err"; then fail 'a catalogue missing a required verb must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-verb-err")" 'missing verb resume-agent' 'a missing verb must be named'
unset SQUAD_TUIOS_FAKE_VERBS_OMIT
SQUAD_TUIOS_FAKE_PARAM_OMIT=close-window:window
export SQUAD_TUIOS_FAKE_PARAM_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-param-err"; then fail 'a catalogue missing a required parameter must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-param-err")" 'close-window has no parameter window' 'a missing parameter must be named'
unset SQUAD_TUIOS_FAKE_PARAM_OMIT
SQUAD_TUIOS_FAKE_VERBS_FAIL=1
export SQUAD_TUIOS_FAKE_VERBS_FAIL
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-fail-err"; then fail 'an unreadable catalogue must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-fail-err")" 'catalogue is unreadable' 'an unreadable catalogue must say so'
unset SQUAD_TUIOS_FAKE_VERBS_FAIL
if SQUAD_TUIOS_FAKE_SESSION_DEAD=1 fm_backend_tuios_container_ensure /tmp/project >/dev/null 2>&1; then
  fail 'a dead session must never reach protocol discovery or be adopted'
fi

[ "$(fm_backend_tuios_boot_id owned)" = 'boot-a' ] || fail 'the daemon boot id must be readable for restart detection'
SQUAD_TUIOS_FAKE_BOOT_ID=boot-b
export SQUAD_TUIOS_FAKE_BOOT_ID
[ "$(fm_backend_tuios_boot_id owned)" = 'boot-b' ] || fail 'a changed daemon boot id must be observable'
unset SQUAD_TUIOS_FAKE_BOOT_ID

# The worktree-discovery probe must work on an attached session, where
# get-window omits the daemon cwd.
SQUAD_TUIOS_FAKE_ATTACHED_CLIENT=1
export SQUAD_TUIOS_FAKE_ATTACHED_CLIENT
[ "$(fm_backend_tuios_current_path owned:w-opaque_7)" = '/tmp/wt' ] || fail 'cwd must come from the daemon inventory while a client is attached'
unset SQUAD_TUIOS_FAKE_ATTACHED_CLIENT

# A flat window: string record without a top-level cwd must not raise a jq
# indexing error from the worktree-discovery probe; it reads as no path.
SQUAD_TUIOS_FAKE_STRING_WINDOW=1
export SQUAD_TUIOS_FAKE_STRING_WINDOW
current_path_out=$(fm_backend_tuios_current_path owned:w-opaque_7 2>"$TMP_ROOT/current-path-err") \
  || fail 'a string-shaped window record must not fail the discovery probe'
[ -z "$current_path_out" ] || fail 'a string-shaped window record carries no cwd, so the probe must be empty'
[ -s "$TMP_ROOT/current-path-err" ] && fail 'a silent read failure must not leak a jq indexing error'
unset SQUAD_TUIOS_FAKE_STRING_WINDOW
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'capture-pane --session owned --window w-opaque_7 --scrollback --lines 10' 'capture did not use supported bounded scrollback flags'

# Operator-controlled payload text must never be parsed as TUIOS options: a
# leading-dash message is a literal payload after `--`, and the exact session
# binding must still precede it.
fm_backend_tuios_send_literal owned:w-opaque_7 '--session evil --window evil' >/dev/null 2>&1 \
  || fail 'leading-dash literal send should reach the CLI'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'send-text --session owned --window w-opaque_7 -- --session evil --window evil' \
  'leading-dash payload must stay literal after -- and keep the explicit session binding'
fm_backend_tuios_send_literal owned:w-opaque_7 '--' >/dev/null 2>&1 \
  || fail 'bare -- literal send should reach the CLI'
[ "$(tail -n1 "$SQUAD_TUIOS_LOG")" = 'send-text --session owned --window w-opaque_7 -- --' ] \
  || fail 'a bare -- payload must not consume the appended session flag'

# --- state and provenance ----------------------------------------------
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'agent inventory should corroborate Pi despite foreground=false'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = idle ] || fail 'a TUIOS-reported rest state must map to idle, never to a hard-coded unknown'

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"working","harness_id":"pi","source":"report","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = busy ] || fail 'a reported working turn must map to busy'
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'a reported working turn is a live agent'
unset SQUAD_TUIOS_FAKE_AGENTS

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","source":"report","confidence":"certain","blocked_by":"approval","needs_you":true}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = blocked ] || fail 'needs_input must map to blocked, never to ordinary work'
unset SQUAD_TUIOS_FAKE_AGENTS

# A restored pane after a daemon restart: the window survives, the shell is new,
# and nothing is attributed to it. This is recovery-grade `dead`, not the silent
# `ambiguous` degradation that never licensed recovery.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","source":"","confidence":"none","needs_you":false}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = dead ] || fail 'a restored agentless pane must be dead, never ambiguous'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'an agentless pane has no busy verdict'
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7 2>/dev/null)" = dead ] || fail 'the recovery classifier must stay dead on a reread'
unset SQUAD_TUIOS_FAKE_AGENTS

# A state with no attribution at all is an incomplete report, not proof of
# absence: recovery must not be licensed from it.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = ambiguous ] || fail 'unattributed non-empty state must remain ambiguous'
unset SQUAD_TUIOS_FAKE_AGENTS

# --- prompt content ----------------------------------------------------
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
assert_contains "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" 'approval: approve Bash: make' \
  'a classified blocking prompt must be readable through the prompt verb'
unset SQUAD_TUIOS_FAKE_AGENTS
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'peek-prompt --session owned --window w-opaque_7 --json' \
  'prompt content must come from the prompt verb'
SQUAD_TUIOS_FAKE_PROMPT_STATE=unblocked
export SQUAD_TUIOS_FAKE_PROMPT_STATE
[ -z "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" ] || fail 'a pane that is not blocked has no prompt summary'
unset SQUAD_TUIOS_FAKE_PROMPT_STATE
[ -z "$(fm_backend_prompt_summary tmux owned:w-opaque_7 2>/dev/null)" ] || fail 'backends without a prompt verb must report no prompt summary'

# --- delivery: the queue path and its distinct verdicts ----------------
# Blocked: nothing is typed, and the distinct verdict names the block.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"question"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
: > "$SQUAD_TUIOS_LOG"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'allow' 3 0 0 sq-task-1)" = agent_blocked ] \
  || fail 'a blocked pane must refuse with agent_blocked'
if grep -qE '^(queue|send-text|send-keys) ' "$SQUAD_TUIOS_LOG"; then
  fail 'a blocked pane must never receive typed text'
fi
unset SQUAD_TUIOS_FAKE_AGENTS

# The agent took the queued entry: an observed postcondition, so delivery is real.
: > "$SQUAD_TUIOS_LOG"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = empty ] \
  || fail 'a queue entry the agent took must confirm delivery'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'queue --session owned --window w-opaque_7 --json -- do work' \
  'the queue path must be used for asynchronous steering, not raw text plus Enter'

# The entry was typed and not taken: a real verdict, and never a success.
SQUAD_TUIOS_FAKE_QUEUE_LS=$(printf '%s' '{"entries":[{"id":"q1","state":"stalled"}]}')
export SQUAD_TUIOS_FAKE_QUEUE_LS
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = stalled ] \
  || fail 'a stalled queue entry must be reported as stalled'
unset SQUAD_TUIOS_FAKE_QUEUE_LS

# Still waiting for the agent's next rest is not a stall: the daemon owns it.
SQUAD_TUIOS_FAKE_QUEUE_LS=$(printf '%s' '{"entries":[{"id":"q1","state":"waiting"}]}')
export SQUAD_TUIOS_FAKE_QUEUE_LS
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = empty ] \
  || fail 'a queue entry waiting for the next rest is a confirmed queueing'
unset SQUAD_TUIOS_FAKE_QUEUE_LS

# A being-typed entry that then stalls is observed across polls before any
# verdict: the first poll must see `delivering`, and only a later `stalled` poll
# may resolve it.
SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ='delivering,stalled'
SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE="$TMP_ROOT/queue-ls-count"
export SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE
printf '0' > "$SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = stalled ] \
  || fail 'a delivering entry that stalls must be reported as stalled'
[ "$(cat "$SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE")" -ge 2 ] \
  || fail 'the delivering->stalled transition must be observed across polls, not resolved on the first'
unset SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE

# A full queue is a refusal that typed nothing, and says so distinctly. The
# second wording is the live TUIOS 0.8.0 message, which carries no code token.
SQUAD_TUIOS_FAKE_QUEUE_FAIL=1 SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: the pane already holds as many queued messages as allowed (queue_full)'
export SQUAD_TUIOS_FAKE_QUEUE_FAIL SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = queue_full ] \
  || fail 'a full queue must be reported as queue_full'
SQUAD_TUIOS_FAKE_QUEUE_ERROR=$(printf '%s' 'queue-prompt failed: the queue for window w-opaque_7 holds 8 messages, as many as [agents.queue] max allows.
Most likely cause: Nothing was queued.
Fix: run tuios queue ls.')
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = queue_full ] \
  || fail 'the live full-queue wording must map to queue_full'
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: the target agent was mid-turn (not_ready)'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = not_ready ] \
  || fail 'a not-ready refusal must be reported as not_ready'
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: the prompt was typed and not taken (prompt_stalled)'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = prompt_stalled ] \
  || fail 'a typed-but-untaken prompt must be reported as prompt_stalled'
# A pane the daemon knows holds no agent keeps the pre-existing literal write,
# which never claims a delivery.
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: window w-opaque_7 runs no agent tuios knows of, so nothing would take a queued prompt.'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
: > "$SQUAD_TUIOS_LOG"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = uncertain-delivery ] \
  || fail 'a pane with no attributable agent must fall back to an honest uncertain delivery'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'send-text --session owned --window w-opaque_7 -- do work' \
  'the no-agent fallback must use the literal write'
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: something undocumented'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = send-failed ] \
  || fail 'an unrecognized refusal must stay a plain send failure'
unset SQUAD_TUIOS_FAKE_QUEUE_FAIL SQUAD_TUIOS_FAKE_QUEUE_ERROR

# --- recovery ----------------------------------------------------------
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"working","harness_id":"pi","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = live ] || fail 'a live agent must never be resumed over'
unset SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"idle","harness_id":"pi","confidence":"certain","agent_session_id":"sid"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = live ] || fail 'an attributed agent between turns must never be resumed over'
unset SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none","agent_session_id":""}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = no_conversation ] || fail 'a pane with no recorded conversation cannot be resumed'
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none","agent_session_id":"sid"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_RESUME_OK=1
export SQUAD_TUIOS_FAKE_RESUME_OK
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 claude)" = resumed ] || fail 'a supported harness must resume the recorded conversation'
unset SQUAD_TUIOS_FAKE_RESUME_OK
SQUAD_TUIOS_FAKE_RESUME_ERROR='harness pi has no resume command (not_resumable)'
export SQUAD_TUIOS_FAKE_RESUME_ERROR
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = unsupported ] || fail 'a harness with no resume command must be reported unsupported'
SQUAD_TUIOS_FAKE_RESUME_ERROR='no conversation is recorded for this pane (not_resumable)'
export SQUAD_TUIOS_FAKE_RESUME_ERROR
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = no_conversation ] || fail 'a missing recorded conversation must be reported'
SQUAD_TUIOS_FAKE_RESUME_ERROR='the pane shell is not at its prompt (not_ready)'
export SQUAD_TUIOS_FAKE_RESUME_ERROR
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 claude)" = not_ready ] || fail 'a shell that is not at its prompt must be reported not_ready'
unset SQUAD_TUIOS_FAKE_RESUME_ERROR SQUAD_TUIOS_FAKE_AGENTS

# Reusing a restored window needs BOTH a changed daemon boot id and a confirmed
# agentless pane; neither alone is enough to authorize a relaunch.
SQUAD_TUIOS_FAKE_RESTORED_WINDOW=1
export SQUAD_TUIOS_FAKE_RESTORED_WINDOW
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old)" = 'w-opaque_7' ] \
  || fail 'a restored agentless window after a boot change must be reusable'
if fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-a >/dev/null 2>&1; then
  fail 'an unchanged daemon boot id must never authorize reuse'
fi
if fm_backend_tuios_reuse_restored_task owned sq-task-1 '' >/dev/null 2>&1; then
  fail 'no recorded boot id must never authorize reuse'
fi
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
if fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old >/dev/null 2>&1; then
  fail 'a window a live agent owns must never be reused'
fi
if fm_backend_tuios_reuse_restored_task owned sq-other-1 boot-old >/dev/null 2>&1; then
  fail 'a window without the task label must never be reused'
fi
unset SQUAD_TUIOS_FAKE_RESTORED_WINDOW SQUAD_TUIOS_FAKE_AGENTS

# The same-label lookup must read identity through the shared normalizer, so an
# inventory that reports the documented `id` key (the default TUIOS shape) is
# reusable after a restart exactly like a `window_id` one.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old)" = 'w-opaque_7' ] \
  || fail 'a restored id-keyed window after a boot change must be reusable'
unset SQUAD_TUIOS_FAKE_AGENTS

# --- inventory safety (unchanged contract) ------------------------------
SQUAD_TUIOS_FAKE_MISSING=1
export SQUAD_TUIOS_FAKE_MISSING
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = missing ] || fail 'successful inventory omission should report missing'
unset SQUAD_TUIOS_FAKE_MISSING

SQUAD_TUIOS_FAKE_ERROR_INVENTORY=1
export SQUAD_TUIOS_FAKE_ERROR_INVENTORY
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a windows-less JSON object must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-dupe /tmp/wt >/dev/null 2>&1; then
  fail 'an unreadable window inventory must refuse duplicate-name creation'
fi
unset SQUAD_TUIOS_FAKE_ERROR_INVENTORY

# An error envelope that still carries a syntactically valid array must never
# read as an authoritative empty inventory, or recovery would relaunch a task.
SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS=1
export SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an error envelope with an empty windows array must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-errwin /tmp/wt >/dev/null 2>&1; then
  fail 'an error-envelope inventory must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-errwin' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'error-envelope inventory must not authorize window creation'
unset SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS

# The single-window read has the same envelope gap: an error that happens to
# carry a matching window object must stay unreadable, never a ready target.
SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW=1
export SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW
if fm_backend_tuios_target_exists owned:w-opaque_7 sq-task-1; then
  fail 'an error envelope that carries a window object must not read as a ready target'
fi
unset SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW

# The agent report reads the agent inventory, whose own error envelope must stay
# unreadable rather than turning into an authoritative agentless verdict.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"error":{"code":"daemon_unreachable"},"agents":[]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an agent-inventory error envelope must keep agent state unreadable'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'an agent-inventory error envelope must keep the busy verdict unknown'
unset SQUAD_TUIOS_FAKE_AGENTS

if fm_backend_tuios_create_task owned sq-task-1 /tmp/wt >/dev/null 2>&1; then
  fail 'an existing TUIOS task label must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-task-1' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'duplicate-label refusal must not create a new window'

# A live agent on the same label must keep refusing: the reuse path is only for
# a restored, agentless window.
SQUAD_TUIOS_FAKE_RESTORED_WINDOW=1
export SQUAD_TUIOS_FAKE_RESTORED_WINDOW
if fm_backend_tuios_create_task owned sq-task-1 /tmp/wt >/dev/null 2>&1; then
  fail 'create_task must never adopt a same-label window on its own'
fi
unset SQUAD_TUIOS_FAKE_RESTORED_WINDOW

# A non-object window element must not read as an empty/duplicate-free inventory:
# jq indexing errors would otherwise fall through and create a second window.
SQUAD_TUIOS_FAKE_BAD_ELEMENT=1
export SQUAD_TUIOS_FAKE_BAD_ELEMENT
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a non-object window element must stay unreadable'
if fm_backend_tuios_create_task owned sq-element /tmp/wt >/dev/null 2>&1; then
  fail 'a non-object window element must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-element' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'malformed inventory must not authorize window creation'
unset SQUAD_TUIOS_FAKE_BAD_ELEMENT

# A window identified as window_id must corroborate presence, never read as
# missing, or the recovery path would authorize a duplicate relaunch.
SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE=1
export SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'window_id-identified inventory must corroborate presence, never report missing'
unset SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE

# Disagreeing identity fields inside one record are a contradiction: reporting
# a lookup-order winner could turn a live window into authoritative absence and
# authorize a duplicate relaunch.
SQUAD_TUIOS_FAKE_CONFLICTING_ID=1
export SQUAD_TUIOS_FAKE_CONFLICTING_ID
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a record whose own identity fields disagree must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-stale /tmp/wt >/dev/null 2>&1; then
  fail 'a contradictory identity record must refuse window creation'
fi
unset SQUAD_TUIOS_FAKE_CONFLICTING_ID

# The duplicate-label guard must read the same nested-first label shape the
# endpoint check reads, or a nested label bypasses duplicate-name refusal.
SQUAD_TUIOS_FAKE_NESTED_LABEL=1
export SQUAD_TUIOS_FAKE_NESTED_LABEL
if fm_backend_tuios_create_task owned sq-nested /tmp/wt >/dev/null 2>&1; then
  fail 'a nested window label must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-nested' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'nested-label refusal must not create a new window'
unset SQUAD_TUIOS_FAKE_NESTED_LABEL

# A live retitle must not hide the durable label that identifies the task.
SQUAD_TUIOS_FAKE_DURABLE_LABEL=1
export SQUAD_TUIOS_FAKE_DURABLE_LABEL
if fm_backend_tuios_create_task owned sq-durable /tmp/wt >/dev/null 2>&1; then
  fail 'a durable custom_name label must refuse duplicate-name creation after a live retitle'
fi
[ "$(grep -c 'new-window sq-durable' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'durable-label refusal must not create a new window'
unset SQUAD_TUIOS_FAKE_DURABLE_LABEL

# An element without a recognizable identity must invalidate the whole
# inventory as unreadable instead of reading as a reliable omission.
SQUAD_TUIOS_FAKE_NO_IDENTITY=1
export SQUAD_TUIOS_FAKE_NO_IDENTITY
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an identity-less window element must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-noid /tmp/wt >/dev/null 2>&1; then
  fail 'an identity-less inventory must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-noid' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'identity-less inventory must not authorize window creation'
unset SQUAD_TUIOS_FAKE_NO_IDENTITY

SQUAD_TUIOS_FAKE_LIST_FAIL=1
export SQUAD_TUIOS_FAKE_LIST_FAIL
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a failed inventory read after a restart must stay unreadable'
unset SQUAD_TUIOS_FAKE_LIST_FAIL

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = ambiguous ] || fail 'unattributed agent must remain ambiguous'
unset SQUAD_TUIOS_FAKE_AGENTS

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":null,"harness_id":"pi","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7 2>/dev/null)" = alive ] || fail 'harness identity fallback must corroborate an agent when foreground is absent'
unset SQUAD_TUIOS_FAKE_AGENTS

SQUAD_TUIOS_SESSION=owned
export SQUAD_TUIOS_SESSION
[ "$(fm_backend_tuios_container_ensure /tmp/project)" = owned ] || fail 'explicitly configured live session should be accepted'
SQUAD_TUIOS_FAKE_SESSION_DEAD=1
export SQUAD_TUIOS_FAKE_SESSION_DEAD
if fm_backend_tuios_container_ensure /tmp/project >/dev/null 2>&1; then
  fail 'a lost or restarted TUIOS session must refuse adoption'
fi
unset SQUAD_TUIOS_FAKE_SESSION_DEAD
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-spawn-test
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
[ "$(fm_backend_tuios_create_task owned sq-spawn-test /tmp/wt | cut -f1)" = w-opaque_7 ] || fail 'task window creation failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-spawn-test --session owned --cwd /tmp/wt --workspace 2 --no-focus --print-id' 'spawn did not create an unfocused task-specific workspace in the exact session'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
# Legacy pid-lock remnants are inert under the kernel lock and must never be
# reclaimed or unlinked by a later allocator.
legacy_lock="$XDG_RUNTIME_DIR/.squad-tuios-workspace-owned.lock"
rm -rf "$legacy_lock"
mkdir -p "$legacy_lock"
printf 'not-a-pid\n' > "$legacy_lock/pid"
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-stale-lock
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
created=$(fm_backend_tuios_create_task owned sq-stale-lock /tmp/wt) || fail 'a legacy corrupt lock must not block task allocation'
[ "${created%%$'\t'*}" = w-opaque_7 ] || fail 'ignoring a legacy lock must still create the task window'
[ -n "${created#*$'\t'}" ] || fail 'create_task must return the selected workspace id'
[ -d "$legacy_lock" ] || fail 'the allocator must not remove a legacy lock directory'
[ -f "$XDG_RUNTIME_DIR/.squad-tuios-workspace-owned.flock" ] || fail 'the stable kernel-lock file must remain after allocation'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME

# Two separate bases share the session lock: a waiter cannot enter TUIOS while
# the first allocator owns the kernel lock, and the later allocation gets a
# different workspace without relying on shared task metadata.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL" \
  "$SQUAD_TUIOS_CREATED_WORKSPACE" "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
mkdir -p "$TMP_ROOT/base-a/state" "$TMP_ROOT/base-a/config" \
  "$TMP_ROOT/base-b/state" "$TMP_ROOT/base-b/config"
(
  SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/base-a/state"
  SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/base-a/config"
  SQUAD_TUIOS_FAKE_ALLOC_PAUSE=1
  SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK="$TMP_ROOT/alloc-paused"
  SQUAD_TUIOS_FAKE_ALLOC_RELEASE="$TMP_ROOT/alloc-release"
  SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
  SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-base-a
  export SQUAD_BACKEND_STATE_DIR SQUAD_BACKEND_CONFIG_DIR \
    SQUAD_TUIOS_FAKE_ALLOC_PAUSE SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK \
    SQUAD_TUIOS_FAKE_ALLOC_RELEASE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
  fm_backend_tuios_create_task owned sq-base-a /tmp/base-a
) > "$TMP_ROOT/base-a.out" 2> "$TMP_ROOT/base-a.err" &
alloc_a_pid=$!
for _ in $(seq 1 500); do
  [ ! -e "$TMP_ROOT/alloc-paused" ] || break
  sleep 0.01
done
[ -e "$TMP_ROOT/alloc-paused" ] || fail 'first allocator did not enter the protected inventory read'
lockfile="$XDG_RUNTIME_DIR/.squad-tuios-workspace-owned.flock"
lock_inode_before=$(stat -c '%d:%i' "$lockfile" 2>/dev/null || stat -f '%d:%i' "$lockfile")
log_lines_before_waiter=$(wc -l < "$SQUAD_TUIOS_LOG")
(
  SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/base-b/state"
  SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/base-b/config"
  SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
  SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-base-b
  export SQUAD_BACKEND_STATE_DIR SQUAD_BACKEND_CONFIG_DIR \
    SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
  fm_backend_tuios_create_task owned sq-base-b /tmp/base-b
) > "$TMP_ROOT/base-b.out" 2> "$TMP_ROOT/base-b.err" &
alloc_b_pid=$!
sleep 0.1
[ "$(wc -l < "$SQUAD_TUIOS_LOG")" -eq "$log_lines_before_waiter" ] || fail 'second base reached TUIOS before the first allocation released the session lock'
touch "$TMP_ROOT/alloc-release"
wait "$alloc_a_pid" || fail "first base allocation failed: $(cat "$TMP_ROOT/base-a.err")"
wait "$alloc_b_pid" || fail "second base allocation failed: $(cat "$TMP_ROOT/base-b.err")"
[ "$(cut -f2 "$TMP_ROOT/base-a.out")" = 2 ] || fail 'the first base did not claim the lowest eligible workspace'
[ "$(cut -f2 "$TMP_ROOT/base-b.out")" = 3 ] || fail 'the waiting base reused the first base workspace'
lock_inode_after=$(stat -c '%d:%i' "$lockfile" 2>/dev/null || stat -f '%d:%i' "$lockfile")
[ "$lock_inode_before" = "$lock_inode_after" ] || fail 'a waiter replaced or unlinked the active session lock inode'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-base-a --session owned --cwd /tmp/base-a --workspace 2 --no-focus --print-id' 'first task was not created without focusing its workspace'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-base-b --session owned --cwd /tmp/base-b --workspace 3 --no-focus --print-id' 'second base did not create an unfocused task in a distinct workspace'
rm -rf "$legacy_lock"
pass 'flock serializes concurrent allocations across bases and keeps the per-session lock inode stable'
printf '2\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE"
printf 'sq-spawn-test\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"

# Every task gets a new workspace after the existing range. The adapter
# requires both workspace discovery and explicit new-window placement support.
fm_backend_tuios_protocol_check owned || fail 'a complete workspace catalogue must pass protocol discovery'
SQUAD_TUIOS_FAKE_VERBS_OMIT='list-workspaces'
export SQUAD_TUIOS_FAKE_VERBS_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-ws-verb-err"; then fail 'a daemon without list-workspaces must refuse per-task placement'; fi
assert_contains "$(cat "$TMP_ROOT/proto-ws-verb-err")" 'missing verb list-workspaces' 'workspace discovery must name its missing verb'
unset SQUAD_TUIOS_FAKE_VERBS_OMIT
SQUAD_TUIOS_FAKE_PARAM_OMIT=new-window:workspace
export SQUAD_TUIOS_FAKE_PARAM_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-ws-param-err"; then fail 'new-window without workspace support must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-ws-param-err")" 'new-window has no parameter workspace' 'placement discovery must name its missing parameter'
unset SQUAD_TUIOS_FAKE_PARAM_OMIT
[ "$(fm_backend_tuios_container_ensure /tmp/project)" = owned ] || fail 'container_ensure must accept a workspace-capable session'
# A configured workspace is only a preference: occupied and named workspaces
# are never selected, and durable task metadata leases an otherwise empty one.
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
printf '4\n' > "$TMP_ROOT/config/tuios-workspace"
[ "$(fm_backend_tuios_next_workspace owned)" = 3 ] || fail 'an occupied configured workspace must be skipped'
printf '2\n' > "$TMP_ROOT/config/tuios-workspace"
printf '2\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE"
printf 'commander-label\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
[ "$(fm_backend_tuios_next_workspace owned)" = 3 ] || fail 'a named empty workspace must be skipped'
rm -f "$SQUAD_TUIOS_CREATED_WORKSPACE" "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
cat > "$TMP_ROOT/state/leased.meta" <<'META'
backend=tuios
tuios_session=owned
tuios_workspace_id=2
META
lease_workspace=$(fm_backend_tuios_next_workspace owned)
[ "$lease_workspace" = 3 ] || fail "a workspace leased by another task must be skipped (selected '$lease_workspace')"
rm -f "$TMP_ROOT/state/leased.meta"
printf '6\n' > "$TMP_ROOT/config/tuios-workspace"
preferred_workspace=$(fm_backend_tuios_next_workspace owned)
[ "$preferred_workspace" = 6 ] || fail "an available configured workspace must be preferred (selected '$preferred_workspace')"
rm -f "$TMP_ROOT/config/tuios-workspace"
# Restore the fake window record for the earlier live task after the selection
# unit fixtures temporarily used the same inventory marker.
printf '2\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE"
printf 'sq-spawn-test\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-grouped
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
[ "$(fm_backend_tuios_create_task owned sq-grouped /tmp/wt | cut -f1)" = w-opaque_7 ] || fail 'per-task workspace creation must succeed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-grouped --session owned --cwd /tmp/wt --workspace 3 --no-focus --print-id' 'a live task window must cause the next task to use another workspace'
# A nested window record carrying workspace under `.window` must verify the
# same exact placement instead of reading as absent.
SQUAD_TUIOS_FAKE_NESTED_WORKSPACE=1 SQUAD_TUIOS_FAKE_PLACEMENT=3
export SQUAD_TUIOS_FAKE_NESTED_WORKSPACE SQUAD_TUIOS_FAKE_PLACEMENT
[ "$(fm_backend_tuios_workspace_for_window owned w-opaque_7)" = 3 ] || fail 'a nested workspace field must be read exactly'
unset SQUAD_TUIOS_FAKE_NESTED_WORKSPACE SQUAD_TUIOS_FAKE_PLACEMENT
# The configured workspace is a preference; a live task makes the next free
# workspace the correct allocation rather than sharing the same screen.
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-next-ws
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
[ "$(fm_backend_tuios_create_task owned sq-next-ws /tmp/wt | cut -f1)" = w-opaque_7 ] || fail 'second task workspace creation must succeed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-next-ws --session owned --cwd /tmp/wt --workspace 2 --no-focus --print-id' 'the next task must take another empty workspace, not the occupied one'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
cat > "$TMP_ROOT/state/next-ws.meta" <<'META'
window=owned:w-opaque_7
endpoint_task_id=next-ws
backend=tuios
tuios_session=owned
tuios_window_id=w-opaque_7
tuios_workspace_id=2
META
rm -f "$SQUAD_TUIOS_CREATED_WINDOW"
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
fm_backend_tuios_release_task_workspace next-ws "$TMP_ROOT/state/next-ws.meta" || fail 'normal teardown must release and unname its empty task workspace'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'set-workspace-name --session owned 2' 'task teardown must clear only its own workspace name'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
rm -f "$TMP_ROOT/state/next-ws.meta"
# A wrong workspace must refuse and close only the just-created window.
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_PLACEMENT=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-wrong-place
export SQUAD_TUIOS_FAKE_PLACEMENT SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-wrong-place /tmp/wt >/dev/null 2>&1; then fail 'wrong-workspace creation must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'a wrong-workspace refusal must close the just-created task window'
unset SQUAD_TUIOS_FAKE_PLACEMENT SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
# A post-creation inventory that omits every workspace field is missing
# placement and must refuse and close only the just-created window.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_NO_WORKSPACE=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-missing-place
export SQUAD_TUIOS_FAKE_NO_WORKSPACE SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-missing-place /tmp/wt >/dev/null 2>&1; then fail 'missing placement must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-missing-place --session owned --cwd /tmp/wt --workspace 2 --no-focus --print-id' 'missing-placement creation must still target the allocated workspace'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'missing placement must close the just-created task window'
unset SQUAD_TUIOS_FAKE_NO_WORKSPACE
# An unreadable post-creation inventory must also close the created window.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-verify-fail
export SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-verify-fail /tmp/wt >/dev/null 2>&1; then fail 'an unreadable post-creation inventory must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'an unverifiable placement must close the just-created task window'
unset SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
# A failed post-creation label read must attempt to close the created window so
# the exact id does not leak and block a retry.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL" "$SQUAD_TUIOS_CREATED_WINDOW.get-window-failed"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-label-fail
export SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-label-fail /tmp/wt >/dev/null 2>&1; then fail 'a failed post-creation label read must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'a failed post-creation label read must close the just-created task window'
unset SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
SQUAD_TUIOS_FAKE_WORKSPACES_FAIL=1
export SQUAD_TUIOS_FAKE_WORKSPACES_FAIL
if fm_backend_tuios_create_task owned sq-unreadable-workspaces /tmp/wt >/dev/null 2>&1; then fail 'unreadable workspace inventory must refuse before creation'; fi
[ "$(grep -c 'new-window sq-unreadable-workspaces' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'unreadable workspace inventory must not create a window'
unset SQUAD_TUIOS_FAKE_WORKSPACES_FAIL SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if SQUAD_TUIOS_SESSION='' PATH="$PATH" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_source tuios; fm_backend_tuios_container_ensure /tmp/project' _ "$ROOT" >/dev/null 2>&1; then
  fail 'missing explicit session must refuse'
fi
if SQUAD_TUIOS_FAKE_VERSION=0.7.9 fm_backend_tuios_tool_check >/dev/null 2>&1; then fail 'old TUIOS must refuse'; fi

no_jq_bin="$TMP_ROOT/no-jq-bin"
mkdir -p "$no_jq_bin"
cp "$TMP_ROOT/fakebin/tuios" "$no_jq_bin/tuios"
# dirname is required while sourcing sq-backend.sh, so it must stay on this
# isolated PATH or the adapter never loads and the check is never reached.
for tool in bash sed head dirname; do
  ln -sf "$(command -v "$tool")" "$no_jq_bin/$tool"
done
if PATH="$no_jq_bin" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_source tuios; fm_backend_tuios_tool_check' _ "$ROOT" 2>"$TMP_ROOT/jq-err" >/dev/null; then
  fail 'missing jq must be refused by the TUIOS tool check'
fi
assert_contains "$(cat "$TMP_ROOT/jq-err")" 'jq' 'missing jq refusal must name the missing tool'
if ! PATH="$no_jq_bin" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_required_tool_available tuios tuios' _ "$ROOT" >/dev/null 2>&1; then
  fail 'an installed TUIOS CLI must remain available when jq is absent'
fi
if PATH="$no_jq_bin" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_required_tool_available tuios jq' _ "$ROOT" >/dev/null 2>&1; then
  fail 'the jq dependency must still be reported unavailable when jq is absent'
fi

# --- cleanup: the native close, scoped to the recorded task window -------
TARGET=owned:w-opaque_7
: > "$SQUAD_TUIOS_LOG"
if fm_backend_tuios_kill "$TARGET" '' wrong-label >/dev/null 2>&1; then fail 'mismatched expected label must refuse cleanup'; fi
[ "$(grep -c 'run-command' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'mismatched label issued a destructive command'
: > "$SQUAD_TUIOS_LOG"
fm_backend_tuios_kill "$TARGET" '' sq-task-1 || fail 'exact task window close failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'cleanup did not use the native close for the exact session and window id'
[ "$(grep -c 'tmux ' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'cleanup must never go through the tmux compatibility shim'
[ "$(grep -c 'kill-session\|kill-server' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'cleanup must never delete a session or the daemon'

# A close the daemon refused must fail loudly with the daemon's own message.
SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE=fail SQUAD_TUIOS_FAKE_CLOSE_MESSAGE='no window found matching w-opaque_7'
export SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE SQUAD_TUIOS_FAKE_CLOSE_MESSAGE
if fm_backend_tuios_kill "$TARGET" '' sq-task-1 2>"$TMP_ROOT/close-err"; then
  fail 'a refused close envelope must not report success'
fi
assert_contains "$(cat "$TMP_ROOT/close-err")" 'no window found matching w-opaque_7' 'a refused close must surface the daemon message'
unset SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE SQUAD_TUIOS_FAKE_CLOSE_MESSAGE

# Cleanup authority binds task id, session, opaque window id, and exact target.
meta="$TMP_ROOT/task.meta"
cat > "$meta" <<'EOF'
backend=tuios
window=owned:w-opaque_7
endpoint_task_id=task-1
worktree=/tmp/wt
project=/tmp/project
kind=strike
tuios_session=owned
tuios_window_id=w-opaque_7
tuios_boot_id=boot-a
EOF
fm_backend_validate_task_endpoint "$meta" task-1 || fail 'valid bound endpoint metadata should pass'
if fm_backend_validate_task_endpoint "$meta" other-task >/dev/null 2>&1; then fail 'mismatched task binding must refuse'; fi

pass 'TUIOS backend: fake CLI covers protocol discovery, real state/prompt mapping, the agent-aware queue verdicts, restart recovery, and the native close'
